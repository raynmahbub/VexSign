// SPDX-License-Identifier: MIT
// VexSign local extension; retain the IDeviceKit wrapper LICENSE.
// One admission slot, retained until the entire native operation and its cleanup retire.
// A timed-out/cancelled WAITER does not make an executing FFI call cancellable.
import Foundation

internal final class DeviceOperationExecutor {
    private let queue = DispatchQueue(label: "com.vexsign.device-operations", qos: .utility)
    private let lock = NSLock()
    private var active: Progress?

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active != nil
    }

    func cancel() {
        lock.lock()
        let token = active
        lock.unlock()
        token?.cancel()
    }

    private func admit(_ token: Progress) throws {
        lock.lock()
        defer { lock.unlock() }
        guard active == nil else { throw DeviceTransportError.operationBusy }
        active = token
    }

    private func retire(_ token: Progress) {
        lock.lock()
        defer { lock.unlock() }
        if active === token { active = nil }
    }

    /// nil bounds neither the waiter nor the work (protected local file commits).
    /// Native work MUST pass a finite waiter timeout. That bounds UI latency only;
    /// no new job may enter while the old call still owns native memory.
    func run<Value>(waiterTimeout: TimeInterval? = nil,
                    _ work: @escaping (Progress) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let token = Progress(totalUnitCount: 1)
        try admit(token)
        let once = DeviceOperationResult<Value>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                let timer: DispatchWorkItem?
                if let seconds = waiterTimeout {
                    let item = DispatchWorkItem {
                        token.cancel()
                        once.resolve(.failure(DeviceTransportError.operationTimedOut))
                    }
                    timer = item
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + (seconds.isFinite ? max(0.01, min(seconds, 300)) : 30), execute: item)
                } else { timer = nil }
                queue.async {
                    // The job, not its waiter, owns this slot and any FFI handles.
                    let result: Result<Value, Error>
                    do {
                        guard !token.isCancelled else { throw DeviceTransportError.operationCancelled }
                        let value = try work(token)
                        // A committed file mutation returns its actual result; callers
                        // re-read status if they cancelled at the commit boundary.
                        if waiterTimeout != nil, token.isCancelled { throw DeviceTransportError.operationCancelled }
                        result = .success(value)
                    } catch { result = .failure(error) }
                    timer?.cancel()
                    self.retire(token)
                    once.resolve(result)
                }
            }
        }, onCancel: {
            token.cancel()
            // File commits are not abandoned mid-rename. Native waiters can leave
            // immediately, without dropping/freeing the worker's owned memory.
            if waiterTimeout != nil { once.resolve(.failure(DeviceTransportError.operationCancelled)) }
        })
    }
}

/// Lock covers both early cancellation (before continuation installation) and a
/// late worker/timer racing to answer. Never hold it while resuming a continuation.
private final class DeviceOperationResult<Value> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var resolved = false

    func install(_ pending: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            pending.resume(with: result)
        } else {
            continuation = pending
            lock.unlock()
        }
    }

    func resolve(_ value: Result<Value, Error>) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        result = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: value)
    }
}
