import Foundation
import NimbleExtensions

/// Exclusive ownership of a stored copy across signing, cloning, packaging,
/// installation and deletion. Leases survive cancellation until workers exit.
final class AppOperationRegistry: @unchecked Sendable {
    static let shared = AppOperationRegistry()
    private let lock = NSLock()
    private var owners: [String: UUID] = [:]

    struct Busy: LocalizedError {
        var errorDescription: String? { .localized("This app is in use by another operation. Wait for it to finish before retrying.") }
    }

    static func key(_ app: AppInfoPresentable) -> String? {
        app.uuid.map { "\(app.isSigned ? "signed" : "imported"):\($0)" }
    }

    func isBusy(_ key: String?) -> Bool {
        guard let key else { return false }
        lock.lock(); defer { lock.unlock() }
        return owners[key] != nil
    }

    /// True while any stored copy is owned by a running operation.
    ///
    /// Signing and installation keep their work files in the temporary directory, so this is
    /// what automatic cleanup asks before it clears that directory.
    var hasActiveOperations: Bool {
        lock.lock(); defer { lock.unlock() }
        return !owners.isEmpty
    }

    func acquire(_ key: String?) throws -> Lease {
        let key = key ?? "anonymous:\(UUID().uuidString)"
        lock.lock(); defer { lock.unlock() }
        guard owners[key] == nil else { throw Busy() }
        let owner = UUID()
        owners[key] = owner
        return Lease { [weak self] in self?.release(key, owner: owner) }
    }

    private func release(_ key: String, owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owners[key] == owner { owners[key] = nil }
    }

    final class Lease: @unchecked Sendable {
        private let release: () -> Void
        fileprivate init(release: @escaping () -> Void) { self.release = release }
        deinit { release() }
    }
}
