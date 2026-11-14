import Foundation

@MainActor
protocol EntitlementsWorkspaceProviding: AnyObject {
    func files() -> [EntitlementsFile]
    func changes() -> AsyncStream<[EntitlementsFile]>
    func fileURL(for entry: EntitlementsFile) -> URL
    func entry(for url: URL) -> EntitlementsFile?
    func load(_ entry: EntitlementsFile) -> [String: Any]
    func save(_ entry: EntitlementsFile, dict: [String: Any]) -> Bool
    func addBlank(name: String) -> EntitlementsFile
    func add(name: String, dict: [String: Any]) -> EntitlementsFile
    func addImported(name: String, from sourceURL: URL) -> EntitlementsFile?
    func parseEntitlements(from url: URL) -> [String: Any]?
    func rename(_ id: UUID, to name: String)
    func delete(_ id: UUID)
}
