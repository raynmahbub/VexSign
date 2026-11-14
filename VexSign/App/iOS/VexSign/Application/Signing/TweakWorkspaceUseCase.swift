import Foundation

@MainActor
final class TweakWorkspaceUseCase {
    private let provider: TweakWorkspaceProviding
    init(provider: TweakWorkspaceProviding) { self.provider = provider }
    func state() -> TweakWorkspaceState { provider.state() }
    func changes() -> AsyncStream<TweakWorkspaceState> { provider.changes() }
    @discardableResult func tweaks(inFolder folderId: UUID?) -> [ManagedTweak] { return provider.tweaks(inFolder: folderId) }
    @discardableResult func tweakCount(inFolder folderId: UUID?) -> Int { return provider.tweakCount(inFolder: folderId) }
    @discardableResult func folder(_ id: UUID?) -> TweakFolder? { return provider.folder(id) }
    @discardableResult func addFolder(name: String) -> TweakFolder { return provider.addFolder(name: name) }
    func renameFolder(_ id: UUID, to name: String) { provider.renameFolder(id, to: name) }
    func deleteFolder(_ id: UUID) { provider.deleteFolder(id) }
    func moveTweaks(_ ids: Set<UUID>, toFolder folderId: UUID?) { provider.moveTweaks(ids, toFolder: folderId) }
    @discardableResult func fileURL(forTweak tweakId: UUID, version: TweakVersion, component: TweakComponent) -> URL { return provider.fileURL(forTweak: tweakId, version: version, component: component) }
    @discardableResult func fileURL(forTweak tweak: ManagedTweak, version: TweakVersion, component: TweakComponent) -> URL { return provider.fileURL(forTweak: tweak, version: version, component: component) }
    @discardableResult func addRepository(_ url: URL) async throws -> Int { return try await provider.addRepository(url) }
    func removeRepository(_ id: UUID) { provider.removeRepository(id) }
    @discardableResult func importTweak(name: String, fromFiles sources: [URL], versionLabel: String = "1.0") async -> ManagedTweak? { return await provider.importTweak(name: name, fromFiles: sources, versionLabel: versionLabel) }
    @discardableResult func importVersion(to tweakId: UUID, fromFiles sources: [URL], label: String) async -> TweakVersion? { return await provider.importVersion(to: tweakId, fromFiles: sources, label: label) }
    @discardableResult func importComponents(to tweakId: UUID, versionId: UUID, fromFiles sources: [URL]) async -> [TweakComponent] { return await provider.importComponents(to: tweakId, versionId: versionId, fromFiles: sources) }
    func deleteComponent(_ componentId: UUID, versionId: UUID, from tweakId: UUID) { provider.deleteComponent(componentId, versionId: versionId, from: tweakId) }
    func mutateComponent(_ componentId: UUID, versionId: UUID, in tweakId: UUID, _ change: (inout TweakComponent) -> Void) { provider.mutateComponent(componentId, versionId: versionId, in: tweakId, change) }
    func deleteTweaksOfferingUndo(_ ids: Set<UUID>) { provider.deleteTweaksOfferingUndo(ids) }
    func deleteVersion(_ versionId: UUID, from tweakId: UUID) { provider.deleteVersion(versionId, from: tweakId) }
    func setSelectedVersion(_ versionId: UUID, for tweakId: UUID) { provider.setSelectedVersion(versionId, for: tweakId) }
    func update(_ tweak: ManagedTweak) { provider.update(tweak) }
    func mutate(_ id: UUID, _ change: (inout ManagedTweak) -> Void) { provider.mutate(id, change) }
    @discardableResult func tweak(_ id: UUID) -> ManagedTweak? { return provider.tweak(id) }
    @discardableResult func injectionSpec(for tweak: ManagedTweak, availableAppex: [String]) -> TweakInjectionSpec? { return provider.injectionSpec(for: tweak, availableAppex: availableAppex) }
    @discardableResult func exportableURL(for tweak: ManagedTweak, version: TweakVersion) -> URL? { return provider.exportableURL(for: tweak, version: version) }
    @discardableResult func exportableURLs(forTweakIds ids: Set<UUID>) -> [URL] { return provider.exportableURLs(forTweakIds: ids) }
    @discardableResult func exportFolder(_ folderId: UUID) -> URL? { return provider.exportFolder(folderId) }
    @discardableResult func stageOneShot(_ urls: [URL]) async throws -> [URL] { return try await provider.stageOneShot(urls) }
    func discardOneShot(_ urls: [URL]) { provider.discardOneShot(urls) }
    @discardableResult func scan(app: LibraryAppReference) throws -> [TweakCandidate] { return try provider.scan(app: app) }
    @discardableResult func extract(ipa url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> TweakExtraction { return try await provider.extract(ipa: url, progress: progress) }
    func discardExtraction(_ directory: URL) { provider.discardExtraction(directory) }
}
