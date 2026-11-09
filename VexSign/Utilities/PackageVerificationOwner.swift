import Foundation

/// In-memory ownership for verification → decision → import. Cancellation is terminal.
/// ImportControl separately owns worker pause/cancellation and the irreversible commit boundary.
final class PackageVerificationOwner {
    private enum State {
        case idle, verifying(UUID), awaitingDecision, importing, cancelled
    }
    private let lock = NSLock()
    private var state: State = .idle

    func begin() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard case .idle = state else { return nil }
        let token = UUID()
        state = .verifying(token)
        return token
    }

    func check(_ token: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard case let .verifying(current) = state, current == token else { throw CancellationError() }
    }

    /// Exactly one verdict can claim a handoff. Late/stale verdicts cannot advance the pipeline.
    func finish(_ token: UUID, requiresDecision: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case let .verifying(current) = state, current == token else { return false }
        state = requiresDecision ? .awaitingDecision : .importing
        return true
    }

    func acceptOverride() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .awaitingDecision = state else { return false }
        state = .importing
        return true
    }

    func cancel() {
        lock.lock()
        state = .cancelled
        lock.unlock()
    }
}
