import Foundation
import Combine

@MainActor
final class TweakWorkspaceAdapter: TweakWorkspaceProviding {
    private let manager: TweakManager
    private let repository: CoreDataWorkspaceRepository
    private var extractions: Set<URL> = []
    init(manager: TweakManager, repository: CoreDataWorkspaceRepository) { self.manager = manager; self.repository = repository }
    func state() -> TweakWorkspaceState {
        TweakWorkspaceState(tweaks: manager.tweaks, folders: manager.folders, repositories: manager.repositories,
            injectableTweaks: manager.injectableTweaks, defaultInjectCount: manager.defaultInjectCount)
    }
    func changes() -> AsyncStream<TweakWorkspaceState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(state())
            let subscription = manager.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in guard let self else { return }; continuation.yield(self.state()) }
            }
            let observation = StreamObservationCancellation(subscription)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
    func tweaks(inFolder folderId: UUID?) -> [ManagedTweak] { return manager.tweaks(inFolder: folderId) }
    func tweakCount(inFolder folderId: UUID?) -> Int { return manager.tweakCount(inFolder: folderId) }
    func folder(_ id: UUID?) -> TweakFolder? { return manager.folder(id) }
    func addFolder(name: String) -> TweakFolder { return manager.addFolder(name: name) }
    func renameFolder(_ id: UUID, to name: String) { manager.renameFolder(id, to: name) }
    func deleteFolder(_ id: UUID) { manager.deleteFolder(id) }
    func moveTweaks(_ ids: Set<UUID>, toFolder folderId: UUID?) { manager.moveTweaks(ids, toFolder: folderId) }
    func fileURL(forTweak tweakId: UUID, version: TweakVersion, component: TweakComponent) -> URL { return manager.fileURL(forTweak: tweakId, version: version, component: component) }
    func fileURL(forTweak tweak: ManagedTweak, version: TweakVersion, component: TweakComponent) -> URL { return manager.fileURL(forTweak: tweak, version: version, component: component) }
    func addRepository(_ url: URL) async throws -> Int { return try await manager.addRepository(url) }
    func removeRepository(_ id: UUID) { manager.removeRepository(id) }
    func importTweak(name: String, fromFiles sources: [URL], versionLabel: String) async -> ManagedTweak? { return await manager.importTweak(name: name, fromFiles: sources, versionLabel: versionLabel) }
    func importVersion(to tweakId: UUID, fromFiles sources: [URL], label: String) async -> TweakVersion? { return await manager.importVersion(to: tweakId, fromFiles: sources, label: label) }
    func importComponents(to tweakId: UUID, versionId: UUID, fromFiles sources: [URL]) async -> [TweakComponent] { return await manager.importComponents(to: tweakId, versionId: versionId, fromFiles: sources) }
    func deleteComponent(_ componentId: UUID, versionId: UUID, from tweakId: UUID) { manager.deleteComponent(componentId, versionId: versionId, from: tweakId) }
    func mutateComponent(_ componentId: UUID, versionId: UUID, in tweakId: UUID, _ change: (inout TweakComponent) -> Void) { manager.mutateComponent(componentId, versionId: versionId, in: tweakId, change) }
    func deleteTweaksOfferingUndo(_ ids: Set<UUID>) { manager.deleteTweaksOfferingUndo(ids) }
    func deleteVersion(_ versionId: UUID, from tweakId: UUID) { manager.deleteVersion(versionId, from: tweakId) }
    func setSelectedVersion(_ versionId: UUID, for tweakId: UUID) { manager.setSelectedVersion(versionId, for: tweakId) }
    func update(_ tweak: ManagedTweak) { manager.update(tweak) }
    func mutate(_ id: UUID, _ change: (inout ManagedTweak) -> Void) { manager.mutate(id, change) }
    func tweak(_ id: UUID) -> ManagedTweak? { return manager.tweak(id) }
    func injectionSpec(for tweak: ManagedTweak, availableAppex: [String]) -> TweakInjectionSpec? { return manager.injectionSpec(for: tweak, availableAppex: availableAppex) }
    func exportableURL(for tweak: ManagedTweak, version: TweakVersion) -> URL? { return manager.exportableURL(for: tweak, version: version) }
    func exportableURLs(forTweakIds ids: Set<UUID>) -> [URL] { return manager.exportableURLs(forTweakIds: ids) }
    func exportFolder(_ folderId: UUID) -> URL? { return manager.exportFolder(folderId) }
    func stageOneShot(_ urls: [URL]) async throws -> [URL] { try await TweakImportSupport.stage(urls) }
    func discardOneShot(_ urls: [URL]) { TweakImportSupport.discard(urls) }
    func scan(app: LibraryAppReference) throws -> [TweakCandidate] {
        let row = try repository.storage.managedApp(matching: app)
        guard let directory = repository.storage.getAppDirectory(for: row) else { throw WorkspaceAccessError.missingRecord }
        return TweakExtractor.candidates(inApp: directory)
    }
    func extract(ipa url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> TweakExtraction {
        let result = try await TweakExtractor.extract(fromIPA: url) { value in Task { @MainActor in progress(value) } }
        let directory = result.workDir.standardizedFileURL
        extractions.insert(directory)
        if Task.isCancelled { discardExtraction(directory); throw CancellationError() }
        return TweakExtraction(workDir: result.workDir, candidates: result.candidates)
    }
    func discardExtraction(_ directory: URL) {
        guard extractions.remove(directory.standardizedFileURL) != nil else { return }
        do { try FileManager.default.removeItem(at: directory) }
        catch { FileLogger.error("Tweak extraction cleanup failed: \(error.localizedDescription)", category: "tweak") }
    }
}
