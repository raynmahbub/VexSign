import Foundation
import Combine

@MainActor
final class EntitlementsWorkspaceModel: ObservableObject {
    @Published private(set) var files: [EntitlementsFile]
    private let useCase: EntitlementsWorkspaceUseCase
    private var observation: Task<Void, Never>?
    init(useCase: EntitlementsWorkspaceUseCase) {
        self.useCase = useCase; files = useCase.files()
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await files in changes {
                guard !Task.isCancelled, let self else { break }
                self.files = files
            }
        }
    }
    deinit { observation?.cancel() }
    @discardableResult func fileURL(for entry: EntitlementsFile) -> URL { defer { files = useCase.files() }; return useCase.fileURL(for: entry) }
    @discardableResult func entry(for url: URL) -> EntitlementsFile? { defer { files = useCase.files() }; return useCase.entry(for: url) }
    @discardableResult func load(_ entry: EntitlementsFile) -> [String: Any] { defer { files = useCase.files() }; return useCase.load(entry) }
    @discardableResult func save(_ entry: EntitlementsFile, dict: [String: Any]) -> Bool { defer { files = useCase.files() }; return useCase.save(entry, dict: dict) }
    @discardableResult func addBlank(name: String) -> EntitlementsFile { defer { files = useCase.files() }; return useCase.addBlank(name: name) }
    @discardableResult func add(name: String, dict: [String: Any]) -> EntitlementsFile { defer { files = useCase.files() }; return useCase.add(name: name, dict: dict) }
    @discardableResult func addImported(name: String, from sourceURL: URL) -> EntitlementsFile? { defer { files = useCase.files() }; return useCase.addImported(name: name, from: sourceURL) }
    @discardableResult func parseEntitlements(from url: URL) -> [String: Any]? { defer { files = useCase.files() }; return useCase.parseEntitlements(from: url) }
    func rename(_ id: UUID, to name: String) { defer { files = useCase.files() }; useCase.rename(id, to: name) }
    func delete(_ id: UUID) { defer { files = useCase.files() }; useCase.delete(id) }
}
