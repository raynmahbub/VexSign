import Foundation

@MainActor
protocol WorkspaceCatalogProviding: AnyObject {
    /// All collections are read together on the store's owning executor.
    func readWorkspace() throws -> WorkspaceSnapshot
    /// Includes inserts, mutations, deletes and merges, not only explicit UI saves.
    func workspaceChanges() -> AsyncStream<Void>
}

@MainActor
protocol LibraryRepository: AnyObject {
    func importPackage(_ source: URL) async throws -> LibraryAppRecord
    func bundleURL(for app: LibraryAppReference) -> URL?
    func artifactURL(for app: LibraryAppReference) -> URL?
    func certificate(for app: LibraryAppReference) -> CertificateRecord?
    func deleteApps(_ apps: [LibraryAppReference]) throws
    func renameApp(_ app: LibraryAppReference, name: String) throws
    func describeApp(_ app: LibraryAppReference, description: String?) throws
    func reorderApps(_ apps: [LibraryAppReference]) throws
}
