import Foundation

/// A display token. The revocable lease clears its callbacks (and any secret
/// captures) when resolved, even when a screen retains an old copy of this value.
struct UndoableRemoval: Identifiable, Sendable {
    let id = UUID()
    let title: String
    private let lease: RemovalUndoLease
    private let lifetime: Duration

    static let announced = Notification.Name("vexsign.removal.announced")
    static let resolved = Notification.Name("vexsign.removal.resolved")
    static let window: Duration = .seconds(6)

    init(title: String, restore: @escaping () -> Bool, discard: @escaping () -> Void,
         lifetime: Duration = UndoableRemoval.window) {
        self.title = title
        self.lifetime = lifetime
        self.lease = RemovalUndoLease(restore: restore, discard: discard)
    }

    /// The timer belongs to the operation, not the banner or its navigation stack.
    static func announce(_ removal: UndoableRemoval) {
        precondition(Thread.isMainThread)
        guard removal.lease.offer(for: removal.lifetime) else { return }
        NotificationCenter.default.post(name: announced, object: nil, userInfo: ["removal": removal])
        Task { @MainActor in
            do { try await Task.sleep(for: removal.lifetime) }
            catch { /* Ending a cancelled offer early is the safe side. */ }
            removal.lease.expire()
            NotificationCenter.default.post(name: resolved, object: nil, userInfo: ["id": removal.id])
        }
    }

    /// Stale copies cannot undo after expiry or restore the same removal twice.
    static func undo(_ removal: UndoableRemoval) -> Bool {
        precondition(Thread.isMainThread)
        guard removal.lease.undo() else { return false }
        NotificationCenter.default.post(name: resolved, object: nil, userInfo: ["id": removal.id])
        return true
    }
}

/// Only callback ownership crosses executors. Mutations are serialized; callbacks
/// run outside the lock. No certificate password or key is put in the UI token.
private final class RemovalUndoLease: @unchecked Sendable {
    private let lock = NSLock()
    private var restore: (() -> Bool)?
    private var discard: (() -> Void)?
    private var deadline: ContinuousClock.Instant?
    private var resolved = false
    private var restoring = false
    private var expirationRequested = false

    init(restore: @escaping () -> Bool, discard: @escaping () -> Void) {
        self.restore = restore; self.discard = discard
    }
    func offer(for lifetime: Duration) -> Bool {
        precondition(Thread.isMainThread)
        lock.lock(); defer { lock.unlock() }
        guard deadline == nil, !resolved else { return false }
        deadline = ContinuousClock().now.advanced(by: lifetime)
        return true
    }
    func undo() -> Bool {
        precondition(Thread.isMainThread)
        lock.lock()
        guard !resolved, !restoring, let deadline else { lock.unlock(); return false }
        guard ContinuousClock().now < deadline else {
            let cleanup = resolveLocked(discarding: true)
            lock.unlock(); cleanup?(); return false
        }
        restoring = true
        let action = restore
        lock.unlock()
        let succeeded = action?() ?? false
        lock.lock()
        restoring = false
        let cleanup: (() -> Void)?
        if succeeded { cleanup = resolveLocked(discarding: false) }
        else if expirationRequested || ContinuousClock().now >= deadline { cleanup = resolveLocked(discarding: true) }
        else { cleanup = nil }
        lock.unlock()
        cleanup?()
        return succeeded
    }
    func expire() {
        precondition(Thread.isMainThread)
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        if restoring { expirationRequested = true; lock.unlock(); return }
        let cleanup = resolveLocked(discarding: true)
        lock.unlock()
        cleanup?()
    }
    private func resolveLocked(discarding: Bool) -> (() -> Void)? {
        resolved = true
        let cleanup = discarding ? discard : nil
        restore = nil
        discard = nil
        return cleanup
    }
}
