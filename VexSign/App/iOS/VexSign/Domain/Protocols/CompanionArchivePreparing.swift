import Foundation

@MainActor
protocol CompanionArchivePreparing: AnyObject {
    func prepareLibrary(_ app: LibraryAppReference, progress: @escaping @MainActor (Double) -> Void) async throws -> URL
    func stage(_ source: URL) async throws -> URL
    /// Host-inbox preparation only; never an installation confirmation.
    func prepareEmbeddedImport(_ stagedURL: URL) async throws -> Bool
    func share(_ stagedURL: URL) throws
    func remove(_ stagedURL: URL) throws
}
