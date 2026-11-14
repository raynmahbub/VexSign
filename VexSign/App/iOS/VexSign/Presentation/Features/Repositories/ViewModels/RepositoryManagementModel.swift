import Foundation
import AltSourceKit

@MainActor
final class RepositoryManagementModel {
    private let useCase: RepositoryManagementUseCase<ASRepository>
    private let workspace: WorkspaceViewModel
    private let platform: PlatformSystemAdapting
    init(useCase: RepositoryManagementUseCase<ASRepository>, workspace: WorkspaceViewModel, platform: PlatformSystemAdapting) {
        self.useCase = useCase
        self.workspace = workspace
        self.platform = platform
    }
    func configuredSources() -> [RepositoryRecord] { workspace.snapshot.repositories }
    func contains(identifier: String) -> Bool { configuredSources().contains { $0.identifier == identifier } }
    func add(_ url: URL, name: String? = "Unknown", identifier: String, iconURL: URL? = nil, completion: @escaping @MainActor (Error?) -> Void) {
        useCase.add(RepositoryConfiguration(url: url, name: name, identifier: identifier, iconURL: iconURL)) { [workspace] error in
            workspace.refresh()
            completion(error)
        }
    }
    func add(_ url: URL, repository: ASRepository, completion: @escaping @MainActor (Error?) -> Void) {
        add(url, name: repository.name, identifier: repository.id ?? url.absoluteString, iconURL: repository.currentIconURL, completion: completion)
    }
    func add(repositories: [URL: ASRepository], completion: @escaping @MainActor (Error?) -> Void) {
        let configurations = repositories.map { RepositoryConfiguration(url: $0.key, name: $0.value.name, identifier: $0.value.id ?? $0.key.absoluteString, iconURL: $0.value.currentIconURL) }
        useCase.add(configurations) { [workspace] error in workspace.refresh(); completion(error) }
    }
    func add(address: String, showAlerts: Bool = false, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        useCase.add(address: address) { [workspace, platform] result in
            workspace.refresh()
            if showAlerts, case .failure(let error) = result { platform.notifyError(error.localizedDescription, sticky: true) }
            completion(result)
        }
    }
    func remove(_ sources: [RepositoryRecord], offeringUndo: Bool = true) {
        do { try useCase.remove(sources, offeringUndo: offeringUndo); workspace.refresh() }
        catch { platform.notifyError(error.localizedDescription, sticky: true) }
    }
    func fetch(from urls: [URL]) async -> [(URL, ASRepository)] { await useCase.fetch(from: urls) }
    func directory() async throws -> [URL] { try await useCase.directory() }
}
