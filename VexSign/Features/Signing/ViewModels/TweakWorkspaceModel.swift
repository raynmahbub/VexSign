import Foundation
import Combine

@MainActor
final class TweakWorkspaceModel: ObservableObject {
    @Published private(set) var state: TweakWorkspaceState
    private let useCase: TweakWorkspaceUseCase
    private var observation: Task<Void, Never>?
    init(useCase: TweakWorkspaceUseCase) {
        self.useCase = useCase; state = useCase.state()
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await state in changes {
                guard !Task.isCancelled, let self else { break }
                self.state = state
            }
        }
    }
    deinit { observation?.cancel() }
    var tweaks: [ManagedTweak] { state.tweaks }
    var folders: [TweakFolder] { state.folders }
    var repositories: [TweakRepository] { state.repositories }
    var injectableTweaks: [ManagedTweak] { state.injectableTweaks }
    var defaultInjectCount: Int { state.defaultInjectCount }
    @discardableResult func tweaks(inFolder folderId: UUID?) -> [ManagedTweak] { defer { state = useCase.state() }; return useCase.tweaks(inFolder: folderId) }
    @discardableResult func tweakCount(inFolder folderId: UUID?) -> Int { defer { state = useCase.state() }; return useCase.tweakCount(inFolder: folderId) }
    @discardableResult func folder(_ id: UUID?) -> TweakFolder? { defer { state = useCase.state() }; return useCase.folder(id) }
    @discardableResult func addFolder(name: String) -> TweakFolder { defer { state = useCase.state() }; return useCase.addFolder(name: name) }
    func renameFolder(_ id: UUID, to name: String) { defer { state = useCase.state() }; useCase.renameFolder(id, to: name) }
    func deleteFolder(_ id: UUID) { defer { state = useCase.state() }; useCase.deleteFolder(id) }
    func moveTweaks(_ ids: Set<UUID>, toFolder folderId: UUID?) { defer { state = useCase.state() }; useCase.moveTweaks(ids, toFolder: folderId) }
    @discardableResult func fileURL(forTweak tweakId: UUID, version: TweakVersion, component: TweakComponent) -> URL { defer { state = useCase.state() }; return useCase.fileURL(forTweak: tweakId, version: version, component: component) }
    @discardableResult func fileURL(forTweak tweak: ManagedTweak, version: TweakVersion, component: TweakComponent) -> URL { defer { state = useCase.state() }; return useCase.fileURL(forTweak: tweak, version: version, component: component) }
    @discardableResult func addRepository(_ url: URL) async throws -> Int { defer { state = useCase.state() }; return try await useCase.addRepository(url) }
    func removeRepository(_ id: UUID) { defer { state = useCase.state() }; useCase.removeRepository(id) }
    @discardableResult func importTweak(name: String, fromFiles sources: [URL], versionLabel: String = "1.0") async -> ManagedTweak? { defer { state = useCase.state() }; return await useCase.importTweak(name: name, fromFiles: sources, versionLabel: versionLabel) }
    @discardableResult func importVersion(to tweakId: UUID, fromFiles sources: [URL], label: String) async -> TweakVersion? { defer { state = useCase.state() }; return await useCase.importVersion(to: tweakId, fromFiles: sources, label: label) }
    @discardableResult func importComponents(to tweakId: UUID, versionId: UUID, fromFiles sources: [URL]) async -> [TweakComponent] { defer { state = useCase.state() }; return await useCase.importComponents(to: tweakId, versionId: versionId, fromFiles: sources) }
    func deleteComponent(_ componentId: UUID, versionId: UUID, from tweakId: UUID) { defer { state = useCase.state() }; useCase.deleteComponent(componentId, versionId: versionId, from: tweakId) }
    func mutateComponent(_ componentId: UUID, versionId: UUID, in tweakId: UUID, _ change: (inout TweakComponent) -> Void) { defer { state = useCase.state() }; useCase.mutateComponent(componentId, versionId: versionId, in: tweakId, change) }
    func deleteTweaksOfferingUndo(_ ids: Set<UUID>) { defer { state = useCase.state() }; useCase.deleteTweaksOfferingUndo(ids) }
    func deleteVersion(_ versionId: UUID, from tweakId: UUID) { defer { state = useCase.state() }; useCase.deleteVersion(versionId, from: tweakId) }
    func setSelectedVersion(_ versionId: UUID, for tweakId: UUID) { defer { state = useCase.state() }; useCase.setSelectedVersion(versionId, for: tweakId) }
    func update(_ tweak: ManagedTweak) { defer { state = useCase.state() }; useCase.update(tweak) }
    func mutate(_ id: UUID, _ change: (inout ManagedTweak) -> Void) { defer { state = useCase.state() }; useCase.mutate(id, change) }
    @discardableResult func tweak(_ id: UUID) -> ManagedTweak? { defer { state = useCase.state() }; return useCase.tweak(id) }
    @discardableResult func injectionSpec(for tweak: ManagedTweak, availableAppex: [String]) -> TweakInjectionSpec? { defer { state = useCase.state() }; return useCase.injectionSpec(for: tweak, availableAppex: availableAppex) }
    @discardableResult func exportableURL(for tweak: ManagedTweak, version: TweakVersion) -> URL? { defer { state = useCase.state() }; return useCase.exportableURL(for: tweak, version: version) }
    @discardableResult func exportableURLs(forTweakIds ids: Set<UUID>) -> [URL] { defer { state = useCase.state() }; return useCase.exportableURLs(forTweakIds: ids) }
    @discardableResult func exportFolder(_ folderId: UUID) -> URL? { defer { state = useCase.state() }; return useCase.exportFolder(folderId) }
    @discardableResult func stageOneShot(_ urls: [URL]) async throws -> [URL] { defer { state = useCase.state() }; return try await useCase.stageOneShot(urls) }
    func discardOneShot(_ urls: [URL]) { defer { state = useCase.state() }; useCase.discardOneShot(urls) }
    @discardableResult func scan(app: LibraryAppReference) throws -> [TweakCandidate] { defer { state = useCase.state() }; return try useCase.scan(app: app) }
    @discardableResult func extract(ipa url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> TweakExtraction { defer { state = useCase.state() }; return try await useCase.extract(ipa: url, progress: progress) }
    func discardExtraction(_ directory: URL) { defer { state = useCase.state() }; useCase.discardExtraction(directory) }
    func scan(app: AppInfoPresentable) throws -> [TweakCandidate] { try useCase.scan(app: LibraryAppReference(app: app)) }
}
