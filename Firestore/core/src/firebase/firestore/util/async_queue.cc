/*
 * Copyright 2018 Google
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

#include "Firestore/core/src/firebase/firestore/util/async_queue.h"

#include <assert.h>
#include <algorithm>
#include <utility>

namespace firebase {
namespace firestore {
namespace util {

DelayedOperation::DelayedOperation(AsyncQueue* const queue,
                                   const TimerId timer_id,
                                   const Seconds delay,
                                   Operation&& operation)
    : data_{std::make_shared<Data>(
          queue, timer_id, delay, std::move(operation))} {
  Schedule(delay);
}

DelayedOperation::Data::Data(AsyncQueue* const queue,
                             const TimerId timer_id,
                             const Seconds delay,
                             Operation&& operation)
    : queue_{queue},
      timer_id_{timer_id},
      target_time_{delay},
      operation_{std::move(operation)} {
}

void DelayedOperation::Cancel() {
  data_->queue_->VerifyIsCurrentQueue();
  if (!data_->done_) {
    MarkDone();
  }
}

void DelayedOperation::Schedule(const Seconds delay) {
  namespace chr = std::chrono;
  const dispatch_time_t delay_ns = dispatch_time(
      DISPATCH_TIME_NOW, chr::duration_cast<chr::nanoseconds>(delay).count());
  dispatch_after_f(
      delay_ns, data_->queue_->native_handle(), this, [](void* const raw_self) {
        const auto self = static_cast<DelayedOperation*>(raw_self);
        self->data_->queue_->EnterCheckedOperation([self] { self->Run(); });
      });
}

void DelayedOperation::Run() {
  data_->queue_->VerifyIsCurrentQueue();
  if (!data_->done_) {
    MarkDone();
    assert(data_->operation_);
    data_->operation_();
  }
}

void DelayedOperation::RunImmediately() {
  data_->queue_->EnqueueAllowingSameQueue([this] { Run(); });
}

void DelayedOperation::MarkDone() {
  data_->done_ = true;
  data_->queue_->Dequeue(*this);
}

// AsyncQueue

void AsyncQueue::Dequeue(const DelayedOperation& dequeued) {
  const auto new_end =
      std::remove(operations_.begin(), operations_.end(), dequeued);
  assert(new_end != operations_.end());
  operations_.erase(new_end, operations_.end());
}

void AsyncQueue::VerifyIsCurrentQueue() const {
  FIREBASE_ASSERT_MESSAGE(
      OnTargetQueue(),
      "We are running on the wrong dispatch queue. Expected '%s' Actual: '%s'",
      GetTargetQueueLabel().c_str(), GetCurrentQueueLabel().c_str());
  FIREBASE_ASSERT_MESSAGE(
      is_operation_in_progress_,
      "verifyIsCurrentQueue called outside enterCheckedOperation on queue '%@'",
      GetTargetQueueLabel().c_str(), GetCurrentQueueLabel().c_str());
}

void AsyncQueue::EnterCheckedOperation(const Operation& operation) {
  FIREBASE_ASSERT_MESSAGE(!is_operation_in_progress_,
                          "EnterCheckedOperation may not be called when an "
                          "operation is in progress");
  is_operation_in_progress_ = true;
  VerifyIsCurrentQueue();
  operation();
  is_operation_in_progress_ = false;
}

void AsyncQueue::Enqueue(const Operation& operation) {
  FIREBASE_ASSERT_MESSAGE(!is_operation_in_progress_ || !OnTargetQueue(),
                          "Enqueue called when we are already running on "
                          "target dispatch queue '%s'",
                          GetTargetQueueLabel().c_str());
  Dispatch(operation);
}

void AsyncQueue::EnqueueAllowingSameQueue(const Operation& operation) {
  Dispatch(operation);
}

DelayedOperation AsyncQueue::EnqueueWithDelay(const Seconds delay,
                                              const TimerId timer_id,
                                              Operation operation) {
  // While not necessarily harmful, we currently don't expect to have multiple
  // callbacks with the same timer_id in the queue, so defensively reject them.
  FIREBASE_ASSERT_MESSAGE(!ContainsDelayedOperationWithTimerId(timer_id),
                          "Attempted to schedule multiple callbacks with id %u",
                          timer_id);

  operations_.emplace_back(this, timer_id, delay, std::move(operation));
  return operations_.back();
}

bool AsyncQueue::ContainsDelayedOperationWithTimerId(
    const TimerId timer_id) const {
  return std::find_if(operations_.begin(), operations_.end(),
                      [timer_id](const DelayedOperation& op) {
                        return op.timer_id() == timer_id;
                      }) != operations_.end();
}

// Private

void AsyncQueue::Dispatch(const Operation& operation) {
  // Note: can't move operation into lambda until C++14.
  const Operation* const wrap =
      new Operation([this, operation] { EnterCheckedOperation(operation); });
  dispatch_async_f(native_handle(), wrap, [](const void* const raw_operation) {
    auto const unwrap = static_cast<const Operation*>(raw_operation);
    unwrap();
    delete unwrap;
  });
}

bool AsyncQueue::OnTargetQueue() const {
  return GetCurrentQueueLabel() == GetTargetQueueLabel();
}

absl::string_view AsyncQueue::GetCurrentQueueLabel() const {
  // Note: dispatch_queue_get_label may return nullptr if the queue wasn't
  // initialized with a label.
  return absl::NullSafeStringView(
      dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL));
}

absl::string_view AsyncQueue::GetTargetQueueLabel() const {
  return absl::NullSafeStringView(dispatch_queue_get_label(native_handle()));
}

}  // namespace util
}  // namespace firestore
}  // namespace firebase