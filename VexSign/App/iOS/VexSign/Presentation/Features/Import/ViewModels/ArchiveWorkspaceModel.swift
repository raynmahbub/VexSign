import Foundation
import Combine

@MainActor
final class ArchiveWorkspaceModel: ObservableObject, Identifiable {
    @Published private(set) var state: ArchiveWorkspaceState
    private let useCase: ArchiveWorkspaceUseCase
    private var observation: Task<Void, Never>?
    init(useCase: ArchiveWorkspaceUseCase) {
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
    var id: String { state.id }
    var appURL: URL { state.appURL }
    var containerURL: URL { state.containerURL }
    var name: String { state.name }
    var sourceDescription: String { state.sourceDescription }
    var displayPath: String { state.displayPath }
    var isLibraryApp: Bool { state.isLibraryApp }
    var changeCount: Int { state.changeCount }
    var isDirty: Bool { changeCount > 0 }
    var isBusy: Bool { state.isBusy }
    var progress: Double { state.progress }
    var totalSize: Int64 { state.totalSize }
    var hasHistory: Bool { state.hasHistory }
    var changes: [IPAChange] { state.changes }
    @discardableResult func createFolder(named name: String, in directory: URL) -> URL? {
        defer { refresh() }; return useCase.createFolder(named: name, in: directory)
    }
    @discardableResult func importFiles(_ urls: [URL], into directory: URL) -> Int {
        defer { refresh() }; return useCase.importFiles(urls, into: directory)
    }
    func save(data: Data, to url: URL) throws { defer { refresh() }; try useCase.save(data: data, to: url) }
    @discardableResult func rename(_ entry: IPAFileEntry, to name: String) -> URL? {
        defer { refresh() }; return useCase.rename(entry, to: name)
    }
    @discardableResult func replace(_ entry: IPAFileEntry, with url: URL) -> Bool {
        defer { refresh() }; return useCase.replace(entry, with: url)
    }
    func delete(_ entry: IPAFileEntry) { useCase.delete(entry); refresh() }
    func undoChange(at url: URL) -> Bool { defer { refresh() }; return useCase.undoChange(at: url) }
    func discardChanges() -> Int { defer { refresh() }; return useCase.discardChanges() }
    func rebuild() async throws -> URL { defer { refresh() }; return try await useCase.rebuild() }
    @discardableResult func signAndSubmitInstallation() async throws -> LibraryAppRecord {
        defer { refresh() }; return try await useCase.signAndSubmitInstallation()
    }
    func discard() { useCase.discard(); refresh() }
    private func refresh() { state = useCase.state() }
}

@MainActor
final class ArchiveCatalogModel {
    private let useCase: ArchiveWorkspaceCatalogUseCase
    init(useCase: ArchiveWorkspaceCatalogUseCase) { self.useCase = useCase }
    func open(ipa url: URL) async throws -> ArchiveWorkspaceModel {
        ArchiveWorkspaceModel(useCase: try await useCase.open(ipa: url))
    }
    func open(recent record: IPAWorkspaceRecord) throws -> ArchiveWorkspaceModel {
        ArchiveWorkspaceModel(useCase: try useCase.open(recent: record))
    }
    func open(app: AppInfoPresentable) throws -> ArchiveWorkspaceModel {
        ArchiveWorkspaceModel(useCase: try useCase.open(app: app))
    }
    func recents() -> [IPAWorkspaceRecord] { useCase.recents() }
    func discardAll() throws { try useCase.discardAll() }
}
