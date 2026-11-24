import Foundation
import Combine

@MainActor
final class EntitlementsWorkspaceAdapter: EntitlementsWorkspaceProviding {
    private let manager: EntitlementsManager
    init(manager: EntitlementsManager) { self.manager = manager }
    func files() -> [EntitlementsFile] { manager.files }
    func changes() -> AsyncStream<[EntitlementsFile]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let subscription = manager.$files.sink { continuation.yield($0) }
            let observation = StreamObservationCancellation(subscription)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
    @discardableResult func fileURL(for entry: EntitlementsFile) -> URL { return manager.fileURL(for: entry) }
    @discardableResult func entry(for url: URL) -> EntitlementsFile? { return manager.entry(for: url) }
    @discardableResult func load(_ entry: EntitlementsFile) -> [String: Any] { return manager.load(entry) }
    @discardableResult func save(_ entry: EntitlementsFile, dict: [String: Any]) -> Bool { return manager.save(entry, dict: dict) }
    @discardableResult func addBlank(name: String) -> EntitlementsFile { return manager.addBlank(name: name) }
    @discardableResult func add(name: String, dict: [String: Any]) -> EntitlementsFile { return manager.add(name: name, dict: dict) }
    @discardableResult func addImported(name: String, from sourceURL: URL) -> EntitlementsFile? { return manager.addImported(name: name, from: sourceURL) }
    @discardableResult func parseEntitlements(from url: URL) -> [String: Any]? { return EntitlementsManager.parseEntitlements(from: url) }
    func rename(_ id: UUID, to name: String) { manager.rename(id, to: name) }
    func delete(_ id: UUID) { manager.delete(id) }
}
