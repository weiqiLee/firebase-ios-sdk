/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/Source/Local/FSTLevelDBQueryCache.h"

#include <leveldb/db.h>
#include <leveldb/write_batch.h>

#import "Firestore/Protos/objc/firestore/local/Target.pbobjc.h"
#import "Firestore/Source/Core/FSTQuery.h"
#import "Firestore/Source/Local/FSTLevelDB.h"
#import "Firestore/Source/Local/FSTLevelDBKey.h"
#import "Firestore/Source/Local/FSTLocalSerializer.h"
#import "Firestore/Source/Local/FSTQueryData.h"
#import "Firestore/Source/Remote/FSTRemoteEvent.h"
#import "Firestore/Source/Util/FSTAssert.h"
#include "Firestore/core/src/firebase/firestore/util/ordered_code.h"
#include "absl/strings/match.h"

#include "Firestore/core/src/firebase/firestore/model/document_key.h"

NS_ASSUME_NONNULL_BEGIN

using firebase::firestore::local::LevelDbTransaction;
using firebase::firestore::util::OrderedCode;
using Firestore::StringView;
using firebase::firestore::model::DocumentKey;
using leveldb::DB;
using leveldb::Slice;
using leveldb::Status;

namespace {

FSTListenSequenceNumber ReadSequenceNumber(const absl::string_view &slice) {
  FSTListenSequenceNumber decoded;
  absl::string_view tmp(slice.data(), slice.size());
  if (OrderedCode::ReadSignedNumIncreasing(&tmp, &decoded)) {
    return decoded;
  } else {
    FSTCFail(@"Failed to read sequence number from a sentinel row");
  }
}
}

@interface FSTLevelDBLRUReferenceDelegate : NSObject<FSTReferenceDelegate>
@end

@interface FSTLevelDBQueryCache ()

/** A write-through cached copy of the metadata for the query cache. */
@property(nonatomic, strong, nullable) FSTPBTargetGlobal *metadata;

@property(nonatomic, strong, readonly) FSTLocalSerializer *serializer;

@end

@implementation FSTLevelDBQueryCache {
  FSTLevelDB *_db;

  /**
   * The last received snapshot version. This is part of `metadata` but we store it separately to
   * avoid extra conversion to/from GPBTimestamp.
   */
  FSTSnapshotVersion *_lastRemoteSnapshotVersion;
}

+ (nullable FSTPBTargetGlobal *)readTargetMetadataWithTransaction:
    (firebase::firestore::local::LevelDbTransaction *)transaction {
  std::string key = [FSTLevelDBTargetGlobalKey key];
  std::string value;
  Status status = transaction->Get(key, &value);
  if (status.IsNotFound()) {
    return nil;
  } else if (!status.ok()) {
    FSTFail(@"metadataForKey: failed loading key %s with status: %s", key.c_str(),
            status.ToString().c_str());
  }

  NSData *data =
      [[NSData alloc] initWithBytesNoCopy:(void *)value.data() length:value.size() freeWhenDone:NO];

  NSError *error;
  FSTPBTargetGlobal *proto = [FSTPBTargetGlobal parseFromData:data error:&error];
  if (!proto) {
    FSTFail(@"FSTPBTargetGlobal failed to parse: %@", error);
  }

  return proto;
}

+ (nullable FSTPBTargetGlobal *)readTargetMetadataFromDB:(std::shared_ptr<DB>)db {
  std::string key = [FSTLevelDBTargetGlobalKey key];
  std::string value;
  Status status = db->Get([FSTLevelDB standardReadOptions], key, &value);
  if (status.IsNotFound()) {
    return nil;
  } else if (!status.ok()) {
    FSTFail(@"metadataForKey: failed loading key %s with status: %s", key.c_str(),
            status.ToString().c_str());
  }

  NSData *data =
      [[NSData alloc] initWithBytesNoCopy:(void *)value.data() length:value.size() freeWhenDone:NO];

  NSError *error;
  FSTPBTargetGlobal *proto = [FSTPBTargetGlobal parseFromData:data error:&error];
  if (!proto) {
    FSTFail(@"FSTPBTargetGlobal failed to parse: %@", error);
  }

  return proto;
}

- (instancetype)initWithDB:(FSTLevelDB *)db serializer:(FSTLocalSerializer *)serializer {
  if (self = [super init]) {
    FSTAssert(db, @"db must not be NULL");
    _db = db;
    _serializer = serializer;
  }
  return self;
}

- (void)start {
  // TODO(gsoltis): switch this usage of ptr to currentTransaction
  FSTPBTargetGlobal *metadata = [FSTLevelDBQueryCache readTargetMetadataFromDB:_db.ptr];
  FSTAssert(
      metadata != nil,
      @"Found nil metadata, expected schema to be at version 0 which ensures metadata existence");
  _lastRemoteSnapshotVersion = [self.serializer decodedVersion:metadata.lastRemoteSnapshotVersion];

  self.metadata = metadata;
}

#pragma mark - FSTQueryCache implementation

- (FSTTargetID)highestTargetID {
  return self.metadata.highestTargetId;
}

- (FSTListenSequenceNumber)highestListenSequenceNumber {
  return self.metadata.highestListenSequenceNumber;
}

- (FSTSnapshotVersion *)lastRemoteSnapshotVersion {
  return _lastRemoteSnapshotVersion;
}

- (void)setLastRemoteSnapshotVersion:(FSTSnapshotVersion *)snapshotVersion {
  _lastRemoteSnapshotVersion = snapshotVersion;
  self.metadata.lastRemoteSnapshotVersion = [self.serializer encodedVersion:snapshotVersion];
  _db.currentTransaction->Put([FSTLevelDBTargetGlobalKey key], self.metadata);
}

- (void)enumerateTargetsUsingBlock:(void (^)(FSTQueryData *queryData, BOOL *stop))block {
  // Enumerate all targets, give their sequence numbers.
  std::string targetPrefix = [FSTLevelDBTargetKey keyPrefix];
  auto it = _db.currentTransaction->NewIterator();
  it->Seek(targetPrefix);
  BOOL stop = NO;
  for (; !stop && it->Valid() && absl::StartsWith(it->key(), targetPrefix); it->Next()) {
    FSTQueryData *target = [self decodedTarget:it->value()];
    block(target, &stop);
  }
}

- (void)enumerateOrphanedDocumentsUsingBlock:
    (void (^)(FSTDocumentKey *docKey, FSTListenSequenceNumber sequenceNumber, BOOL *stop))block {
  std::string documentTargetPrefix = [FSTLevelDBDocumentTargetKey keyPrefix];
  auto it = _db.currentTransaction->NewIterator();
  it->Seek(documentTargetPrefix);
  FSTListenSequenceNumber nextToReport = 0;
  FSTDocumentKey *keyToReport = nil;
  FSTLevelDBDocumentTargetKey *key = [[FSTLevelDBDocumentTargetKey alloc] init];
  BOOL stop = NO;
  for (; !stop && it->Valid() && absl::StartsWith(it->key(), documentTargetPrefix); it->Next()) {
    [key decodeKey:it->key()];
    if (key.isSentinel) {
      // if nextToReport is non-zero, report it, this is a new key so the last one
      // must be orphaned.
      if (nextToReport != 0) {
        block(keyToReport, nextToReport, &stop);
      }
      // set nextToReport to be this sequence number. It's the next one we might
      // report, if we don't find any targets for this document.
      nextToReport = ReadSequenceNumber(it->value());
      keyToReport = key.documentKey;
    } else {
      // set nextToReport to be 0, we know we don't need to report this one since
      // we found a target for it.
      nextToReport = 0;
      keyToReport = nil;
    }
  }
  // if not stop and nextToReport is non-zero, report it. We didn't find any targets for
  // that document, and we weren't asked to stop.
  if (!stop && nextToReport != 0) {
    block(keyToReport, nextToReport, &stop);
  }
}

- (void)saveQueryData:(FSTQueryData *)queryData {
  FSTTargetID targetID = queryData.targetID;
  std::string key = [FSTLevelDBTargetKey keyWithTargetID:targetID];
  _db.currentTransaction->Put(key, [self.serializer encodedQueryData:queryData]);
}

- (BOOL)updateMetadataForQueryData:(FSTQueryData *)queryData {
  BOOL updatedMetadata = NO;

  if (queryData.targetID > self.metadata.highestTargetId) {
    self.metadata.highestTargetId = queryData.targetID;
    updatedMetadata = YES;
  }

  if (queryData.sequenceNumber > self.metadata.highestListenSequenceNumber) {
    self.metadata.highestListenSequenceNumber = queryData.sequenceNumber;
    updatedMetadata = YES;
  }
  return updatedMetadata;
}

- (void)addQueryData:(FSTQueryData *)queryData {
  [self saveQueryData:queryData];

  NSString *canonicalID = queryData.query.canonicalID;
  std::string indexKey =
      [FSTLevelDBQueryTargetKey keyWithCanonicalID:canonicalID targetID:queryData.targetID];
  std::string emptyBuffer;
  _db.currentTransaction->Put(indexKey, emptyBuffer);

  self.metadata.targetCount += 1;
  [self updateMetadataForQueryData:queryData];
  _db.currentTransaction->Put([FSTLevelDBTargetGlobalKey key], self.metadata);
}

- (void)updateQueryData:(FSTQueryData *)queryData {
  [self saveQueryData:queryData];

  if ([self updateMetadataForQueryData:queryData]) {
    _db.currentTransaction->Put([FSTLevelDBTargetGlobalKey key], self.metadata);
  }
}

- (void)removeQueryData:(FSTQueryData *)queryData {
  FSTTargetID targetID = queryData.targetID;

  [self removeMatchingKeysForTargetID:targetID];

  std::string key = [FSTLevelDBTargetKey keyWithTargetID:targetID];
  _db.currentTransaction->Delete(key);

  std::string indexKey =
      [FSTLevelDBQueryTargetKey keyWithCanonicalID:queryData.query.canonicalID targetID:targetID];
  _db.currentTransaction->Delete(indexKey);
  self.metadata.targetCount -= 1;
  _db.currentTransaction->Put([FSTLevelDBTargetGlobalKey key], self.metadata);
}

- (NSUInteger)removeQueriesThroughSequenceNumber:(FSTListenSequenceNumber)sequenceNumber
                                     liveQueries:
                                         (NSDictionary<NSNumber *, FSTQueryData *> *)liveQueries {
  NSUInteger count = 0;
  std::string targetPrefix = [FSTLevelDBTargetKey keyPrefix];
  auto it = _db.currentTransaction->NewIterator();
  it->Seek(targetPrefix);
  for (; it->Valid() && absl::StartsWith(it->key(), targetPrefix); it->Next()) {
    FSTQueryData *queryData = [self decodedTarget:it->value()];
    if (queryData.sequenceNumber <= sequenceNumber && !liveQueries[@(queryData.targetID)]) {
      [self removeQueryData:queryData];
      count++;
    }
  }
  return count;
}

- (int32_t)count {
  return self.metadata.targetCount;
}

/**
 * Parses the given bytes as an FSTPBTarget protocol buffer and then converts to the equivalent
 * query data.
 */
- (FSTQueryData *)decodedTarget:(absl::string_view)encoded {
  NSData *data = [[NSData alloc] initWithBytesNoCopy:(void *)encoded.data()
                                              length:encoded.size()
                                        freeWhenDone:NO];

  NSError *error;
  FSTPBTarget *proto = [FSTPBTarget parseFromData:data error:&error];
  if (!proto) {
    FSTFail(@"FSTPBTarget failed to parse: %@", error);
  }

  return [self.serializer decodedQueryData:proto];
}

- (nullable FSTQueryData *)queryDataForQuery:(FSTQuery *)query {
  // Scan the query-target index starting with a prefix starting with the given query's canonicalID.
  // Note that this is a scan rather than a get because canonicalIDs are not required to be unique
  // per target.
  Slice canonicalID = StringView(query.canonicalID);
  auto indexItererator = _db.currentTransaction->NewIterator();
  std::string indexPrefix = [FSTLevelDBQueryTargetKey keyPrefixWithCanonicalID:canonicalID];
  indexItererator->Seek(indexPrefix);

  // Simultaneously scan the targets table. This works because each (canonicalID, targetID) pair is
  // unique and ordered, so when scanning a table prefixed by exactly one canonicalID, all the
  // targetIDs will be unique and in order.
  std::string targetPrefix = [FSTLevelDBTargetKey keyPrefix];
  auto targetIterator = _db.currentTransaction->NewIterator();

  FSTLevelDBQueryTargetKey *rowKey = [[FSTLevelDBQueryTargetKey alloc] init];
  for (; indexItererator->Valid(); indexItererator->Next()) {
    // Only consider rows matching exactly the specific canonicalID of interest.
    if (!absl::StartsWith(indexItererator->key(), indexPrefix) ||
        ![rowKey decodeKey:indexItererator->key()] || canonicalID != rowKey.canonicalID) {
      // End of this canonicalID's possible targets.
      break;
    }

    // Each row is a unique combination of canonicalID and targetID, so this foreign key reference
    // can only occur once.
    std::string targetKey = [FSTLevelDBTargetKey keyWithTargetID:rowKey.targetID];
    targetIterator->Seek(targetKey);
    if (!targetIterator->Valid() || targetIterator->key() != targetKey) {
      NSString *foundKeyDescription = @"the end of the table";
      if (targetIterator->Valid()) {
        foundKeyDescription = [FSTLevelDBKey descriptionForKey:targetIterator->key()];
      }
      FSTFail(
          @"Dangling query-target reference found: "
          @"%@ points to %@; seeking there found %@",
          [FSTLevelDBKey descriptionForKey:indexItererator->key()],
          [FSTLevelDBKey descriptionForKey:targetKey], foundKeyDescription);
    }

    // Finally after finding a potential match, check that the query is actually equal to the
    // requested query.
    FSTQueryData *target = [self decodedTarget:targetIterator->value()];
    if ([target.query isEqual:query]) {
      return target;
    }
  }

  return nil;
}

#pragma mark Matching Key tracking

- (void)addPotentiallyOrphanedDocuments:(FSTDocumentKeySet *)keys
                       atSequenceNumber:(FSTListenSequenceNumber)sequenceNumber {
  std::string encodedSequenceNumber;
  OrderedCode::WriteSignedNumIncreasing(&encodedSequenceNumber, sequenceNumber);
  [keys enumerateObjectsUsingBlock:^(FSTDocumentKey *documentKey, BOOL *stop) {
    self->_db.currentTransaction->Put(
        [FSTLevelDBDocumentTargetKey sentinelKeyWithDocumentKey:documentKey],
        encodedSequenceNumber);
  }];
}

- (void)addMatchingKeys:(FSTDocumentKeySet *)keys
            forTargetID:(FSTTargetID)targetID
       atSequenceNumber:(FSTListenSequenceNumber)sequenceNumber {
  // Store an empty value in the index which is equivalent to serializing a GPBEmpty message. In the
  // future if we wanted to store some other kind of value here, we can parse these empty values as
  // with some other protocol buffer (and the parser will see all default values).
  std::string emptyBuffer;
  std::string encodedSequenceNumber;
  OrderedCode::WriteSignedNumIncreasing(&encodedSequenceNumber, sequenceNumber);
  [keys enumerateObjectsUsingBlock:^(FSTDocumentKey *documentKey, BOOL *stop) {
    self->_db.currentTransaction->Put(
        [FSTLevelDBTargetDocumentKey keyWithTargetID:targetID documentKey:documentKey],
        emptyBuffer);
    self->_db.currentTransaction->Put(
        [FSTLevelDBDocumentTargetKey keyWithDocumentKey:documentKey targetID:targetID],
        emptyBuffer);
    self->_db.currentTransaction->Put(
        [FSTLevelDBDocumentTargetKey sentinelKeyWithDocumentKey:documentKey],
        encodedSequenceNumber);
  }];
}

- (void)removeMatchingKeys:(FSTDocumentKeySet *)keys
               forTargetID:(FSTTargetID)targetID
          atSequenceNumber:(FSTListenSequenceNumber)sequenceNumber {
  [keys enumerateObjectsUsingBlock:^(FSTDocumentKey *key, BOOL *stop) {
    self->_db.currentTransaction->Delete(
        [FSTLevelDBTargetDocumentKey keyWithTargetID:targetID documentKey:key]);
    self->_db.currentTransaction->Delete(
        [FSTLevelDBDocumentTargetKey keyWithDocumentKey:key targetID:targetID]);
    [self.garbageCollector addPotentialGarbageKey:key];
  }];
}

- (void)removeMatchingKeysForTargetID:(FSTTargetID)targetID {
  std::string indexPrefix = [FSTLevelDBTargetDocumentKey keyPrefixWithTargetID:targetID];
  auto indexIterator = _db.currentTransaction->NewIterator();
  indexIterator->Seek(indexPrefix);

  FSTLevelDBTargetDocumentKey *rowKey = [[FSTLevelDBTargetDocumentKey alloc] init];
  for (; indexIterator->Valid(); indexIterator->Next()) {
    absl::string_view indexKey = indexIterator->key();

    // Only consider rows matching this specific targetID.
    if (![rowKey decodeKey:indexKey] || rowKey.targetID != targetID) {
      break;
    }
    const DocumentKey &documentKey = rowKey.documentKey;

    // Delete both index rows
    _db.currentTransaction->Delete(indexKey);
    _db.currentTransaction->Delete(
        [FSTLevelDBDocumentTargetKey keyWithDocumentKey:documentKey targetID:targetID]);
    [self.garbageCollector addPotentialGarbageKey:documentKey];
  }
}

- (FSTRemovalResult)removeOrphanedDocument:(FSTDocumentKey *)key
                                upperBound:(FSTListenSequenceNumber)upperBound {
  std::string sentinelKey = [FSTLevelDBDocumentTargetKey sentinelKeyWithDocumentKey:key];
  std::string sequenceNumberString;
  Status status = _db.currentTransaction->Get(sentinelKey, &sequenceNumberString);
  if (status.IsNotFound()) {
    return FSTDocumentNonexistent;
  } else if (status.ok()) {
    FSTListenSequenceNumber sequenceNumber = ReadSequenceNumber(sequenceNumberString);
    if (sequenceNumber <= upperBound) {
      _db.currentTransaction->Delete(sentinelKey);
      return FSTDocumentRemoved;
    } else {
      return FSTDocumentRetained;
    }
  } else {
    FSTFail(@"Failed trying to query sentinel key %s", sentinelKey.c_str());
  }
}

- (FSTDocumentKeySet *)matchingKeysForTargetID:(FSTTargetID)targetID {
  std::string indexPrefix = [FSTLevelDBTargetDocumentKey keyPrefixWithTargetID:targetID];
  auto indexIterator = _db.currentTransaction->NewIterator();
  indexIterator->Seek(indexPrefix);

  FSTDocumentKeySet *result = [FSTDocumentKeySet keySet];
  FSTLevelDBTargetDocumentKey *rowKey = [[FSTLevelDBTargetDocumentKey alloc] init];
  for (; indexIterator->Valid(); indexIterator->Next()) {
    absl::string_view indexKey = indexIterator->key();

    // Only consider rows matching this specific targetID.
    if (![rowKey decodeKey:indexKey] || rowKey.targetID != targetID) {
      break;
    }

    result = [result setByAddingObject:rowKey.documentKey];
  }

  return result;
}

- (nullable FSTQueryData *)handleTargetChange:(FSTTargetChange *)change
                                    queryData:(FSTQueryData *)queryData
                                     orphaned:(std::set<FSTDocumentKey *> &)orphaned {
  std::string emptyBuffer;
  std::string encodedSequenceNumber;
  OrderedCode::WriteSignedNumIncreasing(&encodedSequenceNumber, queryData.sequenceNumber);
  FSTTargetMapping *mapping = change.mapping;
  if (mapping) {
    // First make sure that all references are deleted.
    if ([mapping isKindOfClass:[FSTResetMapping class]]) {
      FSTResetMapping *reset = (FSTResetMapping *) mapping;
      std::string targetDocumentPrefix = [FSTLevelDBTargetDocumentKey keyPrefixWithTargetID:queryData.targetID];
      auto targetDocumentIterator = _db.currentTransaction->NewIterator();
      targetDocumentIterator->Seek(targetDocumentPrefix);
      FSTLevelDBTargetDocumentKey *targetDocumentKey = [[FSTLevelDBTargetDocumentKey alloc] init];
      for (; targetDocumentIterator->Valid() &&
                     absl::StartsWith(targetDocumentIterator->key(), targetDocumentPrefix);
              targetDocumentIterator->Next()) {
        absl::string_view currentTargetDocumentKey = targetDocumentIterator->key();
        if (![targetDocumentKey decodeKey:currentTargetDocumentKey]) {
          break;
        }
        std::string docTargetKey =
                [FSTLevelDBDocumentTargetKey keyWithDocumentKey:targetDocumentKey.documentKey
                                                       targetID:targetDocumentKey.targetID];
        _db.currentTransaction->Delete(currentTargetDocumentKey);
        _db.currentTransaction->Delete(docTargetKey);

        FSTDocumentKey *docKey = targetDocumentKey.documentKey;
        if (![self containsKey:docKey] && ![reset.documents containsObject:docKey]) {
          orphaned.insert(docKey);
        }
      }

      for (FSTDocumentKey *key in [reset.documents objectEnumerator]) {
        std::string sentinelKey = [FSTLevelDBDocumentTargetKey sentinelKeyWithDocumentKey:key];
        _db.currentTransaction->Put(sentinelKey, encodedSequenceNumber);
        orphaned.erase(key);

        _db.currentTransaction->Put(
                [FSTLevelDBTargetDocumentKey keyWithTargetID:queryData.targetID documentKey:key],
                emptyBuffer);
        _db.currentTransaction->Put(
                [FSTLevelDBDocumentTargetKey keyWithDocumentKey:key targetID:queryData.targetID],
                emptyBuffer);

      }
    } else if ([mapping isKindOfClass:[FSTUpdateMapping class]]) {
      FSTUpdateMapping *update = (FSTUpdateMapping *)mapping;
      for (FSTDocumentKey *key in [update.removedDocuments objectEnumerator]) {
        std::string docTargetKey =
                [FSTLevelDBDocumentTargetKey keyWithDocumentKey:key targetID:queryData.targetID];
        _db.currentTransaction->Delete(docTargetKey);
        std::string targetDocKey = [FSTLevelDBTargetDocumentKey keyWithTargetID:queryData.targetID documentKey:key];
        _db.currentTransaction->Delete(targetDocKey);
        orphaned.insert(key);
      }

      for (FSTDocumentKey *key in [update.addedDocuments objectEnumerator]) {
        std::string sentinelKey = [FSTLevelDBDocumentTargetKey sentinelKeyWithDocumentKey:key];
        _db.currentTransaction->Put(sentinelKey, encodedSequenceNumber);
        orphaned.erase(key);

        _db.currentTransaction->Put(
                [FSTLevelDBTargetDocumentKey keyWithTargetID:queryData.targetID documentKey:key],
                emptyBuffer);
        _db.currentTransaction->Put(
                [FSTLevelDBDocumentTargetKey keyWithDocumentKey:key targetID:queryData.targetID],
                emptyBuffer);

      }
    } else {
      FSTFail(@"Unknown mapping type: %@", mapping);
    }
  }
  return queryData;
}

#pragma mark - FSTGarbageSource implementation

- (BOOL)containsKey:(const DocumentKey &)key {
  // ignore sentinel rows when determining if a key belongs to a target. Sentinel row just says the
  // document exists, not that it's a member of any particular target.
  std::string indexPrefix = [FSTLevelDBDocumentTargetKey keyPrefixWithResourcePath:key.path()];
  auto indexIterator = _db.currentTransaction->NewIterator();
  indexIterator->Seek(indexPrefix);

  for (; indexIterator->Valid() && absl::StartsWith(indexIterator->key(), indexPrefix);
       indexIterator->Next()) {
    FSTLevelDBDocumentTargetKey *rowKey = [[FSTLevelDBDocumentTargetKey alloc] init];
    if ([rowKey decodeKey:indexIterator->key()] && !rowKey.isSentinel &&
        DocumentKey{rowKey.documentKey} == key) {
      return YES;
    }
  }

  return NO;
}

@end

NS_ASSUME_NONNULL_END
