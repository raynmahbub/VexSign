import Foundation
import Combine

@MainActor
final class ArchiveWorkspaceCatalogAdapter: ArchiveWorkspaceCatalogProviding {
    private let repository: CoreDataWorkspaceRepository
    init(repository: CoreDataWorkspaceRepository) { self.repository = repository }
    func open(ipa url: URL) async throws -> ArchiveWorkspaceProviding {
        ArchiveWorkspaceAdapter(workspace: try await IPAWorkspace.open(ipa: url), repository: repository)
    }
    func open(recent record: IPAWorkspaceRecord) throws -> ArchiveWorkspaceProviding {
        // Do not interpret an arbitrary path supplied by a stale or foreign row.
        guard let current = IPAWorkspace.recents().first(where: { $0.id == record.id }), current.url == record.url else {
            throw WorkspaceAccessError.missingRecord
        }
        return ArchiveWorkspaceAdapter(workspace: try IPAWorkspace.open(recent: current), repository: repository)
    }
    func open(app: LibraryAppReference) throws -> ArchiveWorkspaceProviding {
        let managed = try repository.storage.managedApp(matching: app)
        return ArchiveWorkspaceAdapter(workspace: try IPAWorkspace.open(app: managed), repository: repository)
    }
    func recents() -> [IPAWorkspaceRecord] { IPAWorkspace.recents() }
    func discardAll() throws { try IPAWorkspace.discardAll() }
}

@MainActor
final class ArchiveWorkspaceAdapter: ArchiveWorkspaceProviding {
    private let workspace: IPAWorkspace
    private let repository: CoreDataWorkspaceRepository
    init(workspace: IPAWorkspace, repository: CoreDataWorkspaceRepository) {
        self.workspace = workspace; self.repository = repository
    }
    func state() -> ArchiveWorkspaceState {
        ArchiveWorkspaceState(id: workspace.id, appURL: workspace.appURL, containerURL: workspace.containerURL,
            name: workspace.name, sourceDescription: workspace.sourceDescription, displayPath: workspace.displayPath,
            isLibraryApp: workspace.isLibraryApp, changeCount: workspace.changeCount, isBusy: workspace.isBusy,
            progress: workspace.progress, lastError: workspace.lastError, builtArchive: workspace.builtArchive,
            totalSize: workspace.totalSize, hasHistory: workspace.journal != nil, changes: workspace.journal?.changes ?? [])
    }
    func changes() -> AsyncStream<ArchiveWorkspaceState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(state())
            // IPAWorkspace publishes completed edits, undo/reset, rebuild and
            // progress. Its plain journal is not a second observation owner.
            let subscription = workspace.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    continuation.yield(self.state())
                }
            }
            let observation = StreamObservationCancellation(subscription)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
    private func contains(_ url: URL) -> Bool {
        let root = workspace.containerURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }
    func createFolder(named name: String, in directory: URL) -> URL? {
        guard contains(directory) else { return nil }
        return IPAExplorerActions.createFolder(named: name, in: directory, workspace: workspace)
    }
    func importFiles(_ urls: [URL], into directory: URL) -> Int {
        guard contains(directory) else { return 0 }
        return IPAExplorerActions.importFiles(urls, into: directory, workspace: workspace)
    }
    func save(data: Data, to url: URL) throws {
        guard contains(url) else { throw WorkspaceAccessError.invalidReference }
        try IPAExplorerActions.save(data: data, to: url, workspace: workspace)
    }
    func rename(_ entry: IPAFileEntry, to name: String) -> URL? {
        guard contains(entry.url), entry.url != workspace.appURL, entry.url != workspace.containerURL else { return nil }
        return IPAExplorerActions.rename(entry, to: name, workspace: workspace)
    }
    func replace(_ entry: IPAFileEntry, with url: URL) -> Bool {
        guard contains(entry.url), entry.url != workspace.appURL, entry.url != workspace.containerURL else { return false }
        return IPAExplorerActions.replace(entry, with: url, workspace: workspace)
    }
    func delete(_ entry: IPAFileEntry) {
        guard contains(entry.url), entry.url != workspace.appURL, entry.url != workspace.containerURL else { return }
        IPAExplorerActions.delete(entry, workspace: workspace)
    }
    func undoChange(at url: URL) -> Bool {
        guard contains(url) else { return false }
        do {
            let lease = try workspace.acquireEditingLease()
            defer { withExtendedLifetime(lease) {} }
            return workspace.undoChange(at: url)
        } catch {
            FileLogger.error("Archive undo refused because the workspace is unavailable or busy.", category: "files")
            return false
        }
    }
    func discardChanges() -> Int {
        do {
            let lease = try workspace.acquireEditingLease()
            defer { withExtendedLifetime(lease) {} }
            return workspace.discardChanges()
        } catch {
            FileLogger.error("Archive reset refused because the workspace is unavailable or busy.", category: "files")
            return 0
        }
    }
    func rebuild() async throws -> URL { try await workspace.rebuild() }
    func signAndSubmitInstallation() async throws -> LibraryAppRecord {
        let signed = try await workspace.signAndInstall()
        return try repository.appRecord(signed)
    }
    func discard() {
        do {
            let lease = try workspace.acquireEditingLease()
            defer { withExtendedLifetime(lease) {} }
            workspace.discard()
        } catch {
            FileLogger.error("Archive deletion refused because the workspace is unavailable or busy.", category: "files")
        }
    }
}
