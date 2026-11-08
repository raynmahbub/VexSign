import Foundation

/// Cooperative controls for a single import. Checkpoints run only on its worker;
/// pausing never blocks the UI. Commit is irreversible, so controls close atomically
/// before the database write instead of reporting a cancelled-but-saved import.
final class ImportControl {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var committing = false

    var isControllable: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !cancelled && !committing
    }

    @discardableResult
    func pause() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled && !committing else { return false }
        paused = true
        return true
    }

    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func cancel() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !committing else { return false }
        cancelled = true
        paused = false
        condition.broadcast()
        return true
    }

    func checkpoint() throws {
        condition.lock()
        defer { condition.unlock() }
        try checkpointLocked()
    }

    func beginCommit() throws {
        condition.lock()
        defer { condition.unlock() }
        try checkpointLocked()
        committing = true
    }

    private func checkpointLocked() throws {
        while paused && !cancelled {
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
            if Task.isCancelled { throw CancellationError() }
        }
        if cancelled || Task.isCancelled { throw CancellationError() }
    }
}
