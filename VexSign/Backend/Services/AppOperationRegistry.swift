import Foundation
import NimbleExtensions

/// Exclusive ownership of a stored copy across signing, cloning, packaging,
/// installation and deletion. Leases survive cancellation until workers exit.
final class AppOperationRegistry: @unchecked Sendable {
    static let shared = AppOperationRegistry()
    private let lock = NSLock()
    private var owners: [String: UUID] = [:]
    /// Library copies that are being produced, by identifier, with the number of claims on each.
    private var producing: [String: Int] = [:]
    /// Library copies that were produced and registered since launch, by identifier.
    private var produced: Set<String> = []

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

    // MARK: - Copies produced by this process

    /// Says that a library copy with this identifier is being produced.
    ///
    /// A copy's bundle is moved into the library before its row is committed. In between, nothing
    /// in the library says the folder is wanted, and a cleanup pass takes it for a leftover. Hold
    /// the returned claim while the copy is produced, and call `confirmProduction(of:)` once its
    /// row is committed.
    ///
    /// Giving the claim up without confirming it says the run failed or was cancelled. The folder
    /// is a leftover again then, if the run could not remove it itself.
    ///
    /// A claim is not an operation on a stored copy: it makes nothing busy and does not count in
    /// `hasActiveOperations`.
    func claimProduction(of uuid: String) -> Lease {
        lock.lock(); defer { lock.unlock() }
        producing[uuid, default: 0] += 1
        return Lease { [weak self] in self?.releaseProduction(of: uuid) }
    }

    /// Says that the copy's row is committed. The copy stays known until the app quits.
    ///
    /// It has a row now, so why remember it: a cleanup pass reads the library once and judges
    /// the folders afterwards, seconds later for a large library and sometimes on another
    /// thread. A copy that was produced and registered inside that gap is not among the rows the
    /// pass read, and its claim is gone by the time its folder is judged. This is what still
    /// says the folder is wanted.
    func confirmProduction(of uuid: String) {
        lock.lock(); defer { lock.unlock() }
        produced.insert(uuid)
    }

    /// True when a copy with this identifier is being produced, or was produced and registered
    /// since launch.
    func knowsProduction(of uuid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return producing[uuid] != nil || produced.contains(uuid)
    }

    private func releaseProduction(of uuid: String) {
        lock.lock(); defer { lock.unlock() }
        guard let claims = producing[uuid] else { return }
        producing[uuid] = claims > 1 ? claims - 1 : nil
    }

    final class Lease: @unchecked Sendable {
        private let release: () -> Void
        fileprivate init(release: @escaping () -> Void) { self.release = release }
        deinit { release() }
    }
}
