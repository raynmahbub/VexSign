import Foundation

/// Bundle preparation may overlap, but native signing owns process-wide stdout capture
/// and cache state. Serialize that critical section without blocking the main thread.
actor SigningExecutionGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var occupied = false
    private var waiters: [Waiter] = []
    var waitingCount: Int { waiters.count }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !occupied {
                    occupied = true
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            let next = waiters.removeFirst()
            // Ownership transfers directly; new arrivals cannot jump the queue.
            next.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// The operation runs on the caller's executor, outside this actor. That keeps the
    /// actor responsive to cancellation while a synchronous native operation is busy.
    nonisolated func withPermit<T>(_ operation: () throws -> T) async throws -> T {
        try await acquire()
        do {
            // Cancellation may race the handoff from the previous owner.
            try Task.checkCancellation()
            let value = try operation()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }
}
