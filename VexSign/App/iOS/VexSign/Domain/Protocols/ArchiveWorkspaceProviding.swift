import Foundation

struct ArchiveWorkspaceState {
    let id: String
    let appURL: URL
    let containerURL: URL
    let name: String
    let sourceDescription: String
    let displayPath: String
    let isLibraryApp: Bool
    let changeCount: Int
    let isBusy: Bool
    let progress: Double
    let lastError: String?
    let builtArchive: URL?
    let totalSize: Int64
    let hasHistory: Bool
    let changes: [IPAChange]
}

@MainActor
protocol ArchiveWorkspaceProviding: AnyObject {
    func state() -> ArchiveWorkspaceState
    func changes() -> AsyncStream<ArchiveWorkspaceState>
    func createFolder(named name: String, in directory: URL) -> URL?
    func importFiles(_ urls: [URL], into directory: URL) -> Int
    func save(data: Data, to url: URL) throws
    func rename(_ entry: IPAFileEntry, to name: String) -> URL?
    func replace(_ entry: IPAFileEntry, with url: URL) -> Bool
    func delete(_ entry: IPAFileEntry)
    func undoChange(at url: URL) -> Bool
    func discardChanges() -> Int
    func rebuild() async throws -> URL
    /// Returns the signed library artifact after submission to the existing queue.
    /// It is deliberately not an installation receipt.
    func signAndSubmitInstallation() async throws -> LibraryAppRecord
    func discard()
}

@MainActor
protocol ArchiveWorkspaceCatalogProviding: AnyObject {
    func open(ipa url: URL) async throws -> ArchiveWorkspaceProviding
    func open(recent record: IPAWorkspaceRecord) throws -> ArchiveWorkspaceProviding
    func open(app: LibraryAppReference) throws -> ArchiveWorkspaceProviding
    func recents() -> [IPAWorkspaceRecord]
    func discardAll() throws
}
