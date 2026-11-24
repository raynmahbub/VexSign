import SwiftUI

@MainActor
final class RepositoryBuilderViewModel: ObservableObject {
    @Published private(set) var documents: [RepositoryDocument] = []
    @Published var error: String?
    @Published private(set) var busy = false
    private let useCase: RepositoryBuilderUseCase
    init(useCase: RepositoryBuilderUseCase) { self.useCase = useCase }
    func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false; documents = useCase.documents }
        do { try await useCase.load(); error = nil } catch { self.error = error.localizedDescription }
    }
    func save(_ document: RepositoryDocument) async throws {
        guard !busy else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        busy = true; defer { busy = false; documents = useCase.documents }
        try await useCase.save(document)
    }
    func importFile(_ url: URL) async {
        guard !busy else { return }
        busy = true; defer { busy = false; documents = useCase.documents }
        do { try await useCase.importFile(url); error = nil } catch { self.error = error.localizedDescription }
    }
    func importURL(_ value: String, format: RepositoryFormat) async {
        guard !busy else { return }
        busy = true; defer { busy = false; documents = useCase.documents }
        do { try await useCase.importURL(value, format: format); error = nil } catch { self.error = error.localizedDescription }
    }
    func delete(_ offsets: IndexSet) async {
        guard !busy else { return }
        busy = true; defer { busy = false; documents = useCase.documents }
        do { try await useCase.delete(offsets); error = nil } catch { self.error = error.localizedDescription }
    }
    func validate(_ document: RepositoryDocument) -> [RepositoryIssue] { useCase.validate(document) }
    func checkDownloads(_ document: RepositoryDocument) async -> [RepositoryIssue] { await useCase.checkDownloads(document) }
    func applyingSafeFixes(_ document: RepositoryDocument) -> RepositoryDocument { useCase.applyingSafeFixes(document) }
    func export(_ document: RepositoryDocument) throws -> RepositoryExportData { try useCase.export(document) }
}
