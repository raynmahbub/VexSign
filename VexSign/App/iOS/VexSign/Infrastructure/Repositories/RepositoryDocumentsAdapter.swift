import Foundation

@MainActor
final class RepositoryDocumentsAdapter: RepositoryDocumentsProviding {
    func load() async throws -> [RepositoryDocument] {
        try await EcosystemDatabase.shared.read("builder.documents", as: [RepositoryDocument].self) ?? []
    }
    func save(_ documents: [RepositoryDocument]) async throws { try await EcosystemDatabase.shared.write(documents, key: "builder.documents") }
    func importFile(_ url: URL) async throws -> RepositoryDocument {
        let worker = Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= RepositoryImporter.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            try Task.checkCancellation()
            return try RepositoryImporter.decode(Data(contentsOf: url))
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    func importURL(_ url: URL, format: RepositoryFormat) async throws -> RepositoryDocument {
        try await RepositorySyncEngine.shared.refresh(url, format: format, force: true).document
    }
    func checkDownloads(_ document: RepositoryDocument) async -> [RepositoryIssue] { await RepositoryValidator.checkDownloads(document) }
    func export(_ document: RepositoryDocument) throws -> RepositoryExportData {
        let files = try RepositoryExporter.encode(document, as: document.format)
        return RepositoryExportData(source: files.source, apps: files.apps)
    }
}
