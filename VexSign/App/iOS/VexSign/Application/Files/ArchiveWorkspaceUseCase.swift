import Foundation

@MainActor
final class ArchiveWorkspaceUseCase {
    private let provider: ArchiveWorkspaceProviding
    init(provider: ArchiveWorkspaceProviding) { self.provider = provider }
    func state() -> ArchiveWorkspaceState { provider.state() }
    func changes() -> AsyncStream<ArchiveWorkspaceState> { provider.changes() }
    @discardableResult func createFolder(named name: String, in directory: URL) -> URL? { provider.createFolder(named: name, in: directory) }
    @discardableResult func importFiles(_ urls: [URL], into directory: URL) -> Int { provider.importFiles(urls, into: directory) }
    func save(data: Data, to url: URL) throws { try provider.save(data: data, to: url) }
    @discardableResult func rename(_ entry: IPAFileEntry, to name: String) -> URL? { provider.rename(entry, to: name) }
    @discardableResult func replace(_ entry: IPAFileEntry, with url: URL) -> Bool { provider.replace(entry, with: url) }
    func delete(_ entry: IPAFileEntry) { provider.delete(entry) }
    func undoChange(at url: URL) -> Bool { provider.undoChange(at: url) }
    func discardChanges() -> Int { provider.discardChanges() }
    func rebuild() async throws -> URL { try await provider.rebuild() }
    func signAndSubmitInstallation() async throws -> LibraryAppRecord { try await provider.signAndSubmitInstallation() }
    func discard() { provider.discard() }
}

@MainActor
final class ArchiveWorkspaceCatalogUseCase {
    private let provider: ArchiveWorkspaceCatalogProviding
    init(provider: ArchiveWorkspaceCatalogProviding) { self.provider = provider }
    func open(ipa url: URL) async throws -> ArchiveWorkspaceUseCase {
        ArchiveWorkspaceUseCase(provider: try await provider.open(ipa: url))
    }
    func open(recent record: IPAWorkspaceRecord) throws -> ArchiveWorkspaceUseCase {
        ArchiveWorkspaceUseCase(provider: try provider.open(recent: record))
    }
    func open(app: AppInfoPresentable) throws -> ArchiveWorkspaceUseCase {
        ArchiveWorkspaceUseCase(provider: try provider.open(app: LibraryAppReference(app: app)))
    }
    func recents() -> [IPAWorkspaceRecord] { provider.recents() }
    func discardAll() throws { try provider.discardAll() }
}
