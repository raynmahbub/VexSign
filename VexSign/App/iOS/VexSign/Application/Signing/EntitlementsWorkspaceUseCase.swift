import Foundation

@MainActor
final class EntitlementsWorkspaceUseCase {
    private let provider: EntitlementsWorkspaceProviding
    init(provider: EntitlementsWorkspaceProviding) { self.provider = provider }
    func files() -> [EntitlementsFile] { provider.files() }
    func changes() -> AsyncStream<[EntitlementsFile]> { provider.changes() }
    @discardableResult func fileURL(for entry: EntitlementsFile) -> URL { return provider.fileURL(for: entry) }
    @discardableResult func entry(for url: URL) -> EntitlementsFile? { return provider.entry(for: url) }
    @discardableResult func load(_ entry: EntitlementsFile) -> [String: Any] { return provider.load(entry) }
    @discardableResult func save(_ entry: EntitlementsFile, dict: [String: Any]) -> Bool { return provider.save(entry, dict: dict) }
    @discardableResult func addBlank(name: String) -> EntitlementsFile { return provider.addBlank(name: name) }
    @discardableResult func add(name: String, dict: [String: Any]) -> EntitlementsFile { return provider.add(name: name, dict: dict) }
    @discardableResult func addImported(name: String, from sourceURL: URL) -> EntitlementsFile? { return provider.addImported(name: name, from: sourceURL) }
    @discardableResult func parseEntitlements(from url: URL) -> [String: Any]? { return provider.parseEntitlements(from: url) }
    func rename(_ id: UUID, to name: String) { provider.rename(id, to: name) }
    func delete(_ id: UUID) { provider.delete(id) }
}
