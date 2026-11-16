import Foundation
import Combine
import IDeviceSwift
import NimbleExtensions

@MainActor
final class CompanionArchiveAdapter: CompanionArchivePreparing {
    private let repository: CoreDataWorkspaceRepository
    private let sharing: TemporaryFileSharing
    private var ownedFiles: [URL: AppOperationRegistry.Lease] = [:]
    private var sharingFiles: Set<URL> = []
    private var embeddedReaders: Set<URL> = []
    private var deferredRemovals: Set<URL> = []
    init(repository: CoreDataWorkspaceRepository, sharing: TemporaryFileSharing) {
        self.repository = repository; self.sharing = sharing
    }

    func prepareLibrary(_ reference: LibraryAppReference, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let temporaryLease = try AppOperationRegistry.shared.acquireTemporaryWork()
        defer { withExtendedLifetime(temporaryLease) {} }
        let row = try repository.storage.managedApp(matching: reference)
        let app = try repository.appRecord(row)
        let lease = try AppOperationRegistry.shared.acquire(AppOperationRegistry.key(app))
        defer { withExtendedLifetime(lease) {} }
        let status = InstallerStatusViewModel(isIdevice: false)
        let handler = ArchiveHandler(app: app, viewModel: status)
        let center = UnifiedTaskCenter.shared
        let record = center.begin(kind: .export, title: app.name ?? .localized("Application"),
            subtitle: .localized("Preparing companion IPA"), phase: .queued)
        let taskID = record.id
        let observation = status.$packageProgress.sink { value in
            Task { @MainActor in
                guard let task = (center.tasks + center.history).first(where: { $0.id == taskID }),
                      !task.phase.isTerminal else { return }
                progress(value)
                center.update(task, progress: value)
            }
        }
        defer { observation.cancel() }
        let worker = Task.detached(priority: .userInitiated) {
            try await handler.prepareCompanionArchive()
        }
        do {
            let package = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            if Task.isCancelled {
                try FileManager.default.removeItem(at: package.deletingLastPathComponent())
                throw CancellationError()
            }
            ownedFiles[package.standardizedFileURL] = temporaryLease
            UnifiedTaskCenter.shared.transition(record, to: .completed)
            return package
        } catch {
            UnifiedTaskCenter.shared.transition(record, to: error is CancellationError ? .cancelled : .failed,
                error: error is CancellationError ? nil : error.localizedDescription)
            throw error
        }
    }
    func stage(_ source: URL) async throws -> URL {
        let lease = try AppOperationRegistry.shared.acquireTemporaryWork()
        defer { withExtendedLifetime(lease) {} }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let record = UnifiedTaskCenter.shared.begin(kind: .export, title: source.lastPathComponent,
            subtitle: .localized("Copying IPA for sharing…"), phase: .queued)
        let worker = Task.detached(priority: .userInitiated) { try CompanionIPAStager.copy(source) }
        do {
            let copy = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            if Task.isCancelled {
                try FileManager.default.removeItem(at: copy.deletingLastPathComponent())
                throw CancellationError()
            }
            ownedFiles[copy.standardizedFileURL] = lease
            UnifiedTaskCenter.shared.transition(record, to: .completed)
            return copy
        } catch {
            UnifiedTaskCenter.shared.transition(record, to: error is CancellationError ? .cancelled : .failed,
                error: error is CancellationError ? nil : error.localizedDescription)
            throw error
        }
    }
    func prepareEmbeddedImport(_ stagedURL: URL) async throws -> Bool {
        try Task.checkCancellation()
        let key = stagedURL.standardizedFileURL
        guard let lease = ownedFiles[key], !sharingFiles.contains(key), !embeddedReaders.contains(key) else {
            throw WorkspaceAccessError.invalidReference
        }
        embeddedReaders.insert(key)
        // A disappearing screen may request removal while the synchronous host
        // copy is still reading. Keep both the source and cleanup lease alive.
        defer {
            withExtendedLifetime(lease) {}
            embeddedReaders.remove(key)
            if deferredRemovals.remove(key) != nil {
                do { try remove(stagedURL) }
                catch { FileLogger.error("Could not remove completed embedded handoff source.", category: "install") }
            }
        }
        let worker = Task.detached(priority: .userInitiated) { try EmbeddedContainerRuntime.stageIPA(stagedURL) }
        let accepted = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        // Once accepted, the host owns its independent inbox copy. Cancellation
        // must not erase that copy or trigger a new session switch.
        try Task.checkCancellation()
        return accepted
    }
    func share(_ stagedURL: URL) throws {
        let key = stagedURL.standardizedFileURL
        guard ownedFiles[key] != nil, !sharingFiles.contains(key), !embeddedReaders.contains(key) else { throw WorkspaceAccessError.invalidReference }
        sharingFiles.insert(key)
        do {
            try sharing.shareFile(stagedURL) { [self] in
                sharingFiles.remove(key)
                if deferredRemovals.remove(key) != nil {
                    do { try remove(stagedURL) }
                    catch { FileLogger.error("Could not remove completed companion handoff.", category: "install") }
                }
            }
        } catch {
            sharingFiles.remove(key)
            throw error
        }
    }
    func remove(_ stagedURL: URL) throws {
        let key = stagedURL.standardizedFileURL
        guard ownedFiles[key] != nil else { throw WorkspaceAccessError.invalidReference }
        // A dismissed screen cannot erase a file a share extension is reading.
        if sharingFiles.contains(key) || embeddedReaders.contains(key) { deferredRemovals.insert(key); return }
        if FileManager.default.fileExists(atPath: stagedURL.deletingLastPathComponent().path) {
            try FileManager.default.removeItem(at: stagedURL.deletingLastPathComponent())
        }
        ownedFiles.removeValue(forKey: key)
    }
}
