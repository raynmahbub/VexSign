import SwiftUI

@MainActor
final class RepositoryBuilderViewModel: ObservableObject {
    @Published private(set) var documents: [RepositoryDocument] = []
    @Published var error: String?
    @Published private(set) var busy = false
    private var loaded = false

    func load() async {
        guard !loaded else { return }
        busy = true; defer { busy = false }
        do {
            documents = try await EcosystemDatabase.shared.read("builder.documents", as: [RepositoryDocument].self) ?? []
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
    func save(_ document: RepositoryDocument) async throws {
        guard loaded, !busy else { throw RepositoryError.invalid("Please wait for the repository library to load.") }
        busy = true; defer { busy = false }
        var next = documents
        if let index = next.firstIndex(where: { $0.id == document.id }) { next[index] = document }
        else { next.append(document) }
        try await EcosystemDatabase.shared.write(next, key: "builder.documents")
        documents = next
    }
    func importFile(_ url: URL) async {
        do {
            let document = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= RepositoryImporter.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                return try RepositoryImporter.decode(Data(contentsOf: url))
            }.value
            try await save(document)
        } catch { self.error = error.localizedDescription }
    }
    func importURL(_ value: String, format: RepositoryFormat) async {
        do {
            guard let url = URL(string: value) else { throw URLError(.badURL) }
            var document = try await RepositorySyncEngine.shared.refresh(url, format: format, force: true).document
            document.id = UUID()
            try await save(document)
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ offsets: IndexSet) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        var next = documents; next.remove(atOffsets: offsets)
        do {
            try await EcosystemDatabase.shared.write(next, key: "builder.documents")
            documents = next
        } catch { self.error = error.localizedDescription }
    }
}
