import Foundation

struct RepositoryExportData { let source: Data; let apps: Data }

@MainActor
protocol RepositoryDocumentsProviding: AnyObject {
    func load() async throws -> [RepositoryDocument]
    func save(_ documents: [RepositoryDocument]) async throws
    func importFile(_ url: URL) async throws -> RepositoryDocument
    func importURL(_ url: URL, format: RepositoryFormat) async throws -> RepositoryDocument
    func checkDownloads(_ document: RepositoryDocument) async -> [RepositoryIssue]
    func export(_ document: RepositoryDocument) throws -> RepositoryExportData
}
