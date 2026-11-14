import Foundation

@MainActor
final class RepositoryBuilderUseCase {
    private let provider: RepositoryDocumentsProviding
    private(set) var documents: [RepositoryDocument] = []
    private var loaded = false
    private var busy = false
    init(provider: RepositoryDocumentsProviding) { self.provider = provider }
    func load() async throws {
        guard !loaded else { return }
        guard !busy else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        busy = true; defer { busy = false }
        documents = try await provider.load()
        loaded = true
    }
    private func beginMutation() throws {
        guard loaded, !busy else { throw RepositoryError.invalid("Please wait for the repository library to load.") }
        busy = true
    }
    private func upsert(_ document: RepositoryDocument) async throws {
        var next = documents
        if let index = next.firstIndex(where: { $0.id == document.id }) { next[index] = document }
        else { next.append(document) }
        try await provider.save(next)
        documents = next
    }
    func save(_ document: RepositoryDocument) async throws {
        try beginMutation(); defer { busy = false }
        try await upsert(document)
    }
    func importFile(_ url: URL) async throws {
        try beginMutation(); defer { busy = false }
        let document = try await provider.importFile(url)
        try Task.checkCancellation()
        try await upsert(document)
    }
    func importURL(_ value: String, format: RepositoryFormat) async throws {
        try beginMutation(); defer { busy = false }
        guard let url = RepositoryValidator.webURL(value) else { throw URLError(.badURL) }
        var document = try await provider.importURL(url, format: format)
        try Task.checkCancellation()
        document.id = UUID()
        try await upsert(document)
    }
    func delete(_ offsets: IndexSet) async throws {
        try beginMutation(); defer { busy = false }
        guard offsets.allSatisfy({ documents.indices.contains($0) }) else { throw WorkspaceAccessError.invalidReference }
        var next = documents
        for index in offsets.sorted(by: >) { next.remove(at: index) }
        try await provider.save(next)
        documents = next
    }
    func validate(_ document: RepositoryDocument) -> [RepositoryIssue] { RepositoryValidator.validate(document) }
    func checkDownloads(_ document: RepositoryDocument) async -> [RepositoryIssue] { await provider.checkDownloads(document) }
    func applyingSafeFixes(_ document: RepositoryDocument) -> RepositoryDocument {
        var result = document; RepositoryValidator.applySafeFixes(to: &result); return result
    }
    func export(_ document: RepositoryDocument) throws -> RepositoryExportData { try provider.export(document) }
}
