import Foundation

struct TweakWorkspaceState {
    let tweaks: [ManagedTweak]
    let folders: [TweakFolder]
    let repositories: [TweakRepository]
    let injectableTweaks: [ManagedTweak]
    let defaultInjectCount: Int
}
struct TweakExtraction {
    let workDir: URL
    let candidates: [TweakCandidate]
}

@MainActor
protocol TweakWorkspaceProviding: AnyObject {
    func state() -> TweakWorkspaceState
    func changes() -> AsyncStream<TweakWorkspaceState>
    func tweaks(inFolder folderId: UUID?) -> [ManagedTweak]
    func tweakCount(inFolder folderId: UUID?) -> Int
    func folder(_ id: UUID?) -> TweakFolder?
    func addFolder(name: String) -> TweakFolder
    func renameFolder(_ id: UUID, to name: String)
    func deleteFolder(_ id: UUID)
    func moveTweaks(_ ids: Set<UUID>, toFolder folderId: UUID?)
    func fileURL(forTweak tweakId: UUID, version: TweakVersion, component: TweakComponent) -> URL
    func fileURL(forTweak tweak: ManagedTweak, version: TweakVersion, component: TweakComponent) -> URL
    func addRepository(_ url: URL) async throws -> Int
    func removeRepository(_ id: UUID)
    func importTweak(name: String, fromFiles sources: [URL], versionLabel: String) async -> ManagedTweak?
    func importVersion(to tweakId: UUID, fromFiles sources: [URL], label: String) async -> TweakVersion?
    func importComponents(to tweakId: UUID, versionId: UUID, fromFiles sources: [URL]) async -> [TweakComponent]
    func deleteComponent(_ componentId: UUID, versionId: UUID, from tweakId: UUID)
    func mutateComponent(_ componentId: UUID, versionId: UUID, in tweakId: UUID, _ change: (inout TweakComponent) -> Void)
    func deleteTweaksOfferingUndo(_ ids: Set<UUID>)
    func deleteVersion(_ versionId: UUID, from tweakId: UUID)
    func setSelectedVersion(_ versionId: UUID, for tweakId: UUID)
    func update(_ tweak: ManagedTweak)
    func mutate(_ id: UUID, _ change: (inout ManagedTweak) -> Void)
    func tweak(_ id: UUID) -> ManagedTweak?
    func injectionSpec(for tweak: ManagedTweak, availableAppex: [String]) -> TweakInjectionSpec?
    func exportableURL(for tweak: ManagedTweak, version: TweakVersion) -> URL?
    func exportableURLs(forTweakIds ids: Set<UUID>) -> [URL]
    func exportFolder(_ folderId: UUID) -> URL?
    func stageOneShot(_ urls: [URL]) async throws -> [URL]
    func discardOneShot(_ urls: [URL])
    func scan(app: LibraryAppReference) throws -> [TweakCandidate]
    func extract(ipa url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> TweakExtraction
    func discardExtraction(_ directory: URL)
}
