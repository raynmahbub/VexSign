import Foundation
import os
import NimbleExtensions

/// Exclusive ownership of a stored copy across signing, cloning, packaging,
/// installation and deletion. Leases survive cancellation until workers exit.
///
/// The state lives in an `OSAllocatedUnfairLock` rather than in actor isolation, because half of
/// this type's contract is synchronous: `AppFileHandler.init` and `SigningHandler.init` claim a
/// production slot before any asynchronous work exists, `StorageManager.owns(_:signed:)` answers
/// while judging folders, and `TempStorageSweeper.sweep(maxAge:)` is documented as safe to call
/// from any queue. An actor cannot expose those, and an `async` variant would push an `await` into
/// code that has no asynchronous context to take it. The lock is the same trade already recorded
/// for `BackgroundWorkCompletionFlag` and `BackgroundTaskCompletionGate`.
final class AppOperationRegistry: Sendable {
    static let shared = AppOperationRegistry()
    private let state = OSAllocatedUnfairLock(initialState: State())

    struct Busy: LocalizedError {
        var errorDescription: String? { .localized("This app is in use by another operation. Wait for it to finish before retrying.") }
    }

    init() {}

    static func key(_ app: AppInfoPresentable) -> String? {
        app.uuid.map { "\(app.isSigned ? "signed" : "imported"):\($0)" }
    }

    func isBusy(_ key: String?) -> Bool {
        guard let key else { return false }
        return state.withLock { $0.owners[key] != nil }
    }

    /// True while any stored copy is owned by a running operation.
    ///
    /// Signing and installation keep their work files in the temporary directory, so this is
    /// what automatic cleanup asks before it clears that directory.
    var hasActiveOperations: Bool {
        return state.withLock { !$0.owners.isEmpty }
    }

    func acquire(_ key: String?) throws -> Lease {
        let key = key ?? "anonymous:\(UUID().uuidString)"
        let owner = UUID()
        try state.withLock { current in
            guard current.cleanupOwner == nil, current.owners[key] == nil else { throw Busy() }
            current.owners[key] = owner
        }
        return Lease { [weak self] in
            self?.release(key, owner: owner)
        }
    }

    /// Atomically excludes new registered operations until destructive cleanup finishes.
    func acquireCleanup() -> Lease? {
        let owner = UUID()
        let claimed = state.withLock { current -> Bool in
            guard current.owners.isEmpty, current.producing.isEmpty,
                  current.temporaryWorkers.isEmpty, current.cleanupOwner == nil else { return false }
            current.cleanupOwner = owner
            return true
        }
        guard claimed else { return nil }
        return Lease { [weak self] in
            self?.releaseCleanup(owner)
        }
    }

    /// Non-library work that uses shared temporary files (imports and backup staging).
    func acquireTemporaryWork() throws -> Lease {
        let owner = UUID()
        try state.withLock { current in
            guard current.cleanupOwner == nil else { throw Busy() }
            current.temporaryWorkers.insert(owner)
        }
        return Lease { [weak self] in
            self?.releaseTemporaryWork(owner)
        }
    }

    private func releaseTemporaryWork(_ owner: UUID) {
        _ = state.withLock { $0.temporaryWorkers.remove(owner) }
    }

    private func releaseCleanup(_ owner: UUID) {
        state.withLock { current in
            if current.cleanupOwner == owner { current.cleanupOwner = nil }
        }
    }

    private func release(_ key: String, owner: UUID) {
        state.withLock { current in
            if current.owners[key] == owner { current.owners[key] = nil }
        }
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
        state.withLock { $0.producing[uuid, default: 0] += 1 }
        return Lease { [weak self] in
            self?.releaseProduction(of: uuid)
        }
    }

    /// Says that the copy's row is committed. The copy stays known until the app quits.
    ///
    /// It has a row now, so why remember it: a cleanup pass reads the library once and judges
    /// the folders afterwards, seconds later for a large library and sometimes on another
    /// thread. A copy that was produced and registered inside that gap is not among the rows the
    /// pass read, and its claim is gone by the time its folder is judged. This is what still
    /// says the folder is wanted.
    func confirmProduction(of uuid: String) {
        _ = state.withLock { $0.produced.insert(uuid) }
    }

    /// True when a copy with this identifier is being produced, or was produced and registered
    /// since launch.
    func knowsProduction(of uuid: String) -> Bool {
        return state.withLock { $0.producing[uuid] != nil || $0.produced.contains(uuid) }
    }

    private func releaseProduction(of uuid: String) {
        state.withLock { current in
            guard let claims = current.producing[uuid] else { return }
            current.producing[uuid] = claims > 1 ? claims - 1 : nil
        }
    }

    /// Every mutable field is reachable only through the lock, so the value is `Sendable` and the
    /// registry needs no `@unchecked` escape of its own.
    private struct State: Sendable {
        var owners: [String: UUID] = [:]
        var cleanupOwner: UUID?
        var temporaryWorkers: Set<UUID> = []
        /// Library copies that are being produced, by identifier, with the number of claims on each.
        var producing: [String: Int] = [:]
        /// Library copies that were produced and registered since launch, by identifier.
        var produced: Set<String> = []
    }

    final class Lease: @unchecked Sendable {
        private let release: () -> Void
        fileprivate init(release: @escaping () -> Void) { self.release = release }
        deinit { release() }
    }
}