//
//  InstallQueueAdvanceScheduler.swift
//  VexSign
//
//  Delay between one install finishing and the next one starting.
//

import Foundation

/// Holds the pending advance of the queue.
///
/// A `Task` that sleeps is not enough on its own: Skip, Retry, Stop and a reset all have to be
/// able to drop a dismissal that is already scheduled, and a cancelled run must not wake up and
/// advance a different app. `cancel()` is therefore part of the contract, and `schedule(after:)`
/// cancels whatever was pending before it arms a new one.
final class InstallQueueAdvanceScheduler {
    private var pendingTask: Task<Void, Never>?

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        cancel()
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingTask = nil
            action()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}