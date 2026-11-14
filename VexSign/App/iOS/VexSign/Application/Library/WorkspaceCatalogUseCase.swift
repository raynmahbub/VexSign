import Foundation

/// One application-facing read boundary for SwiftUI and UIKit. The store adapter
/// owns observation; consumers never carry fetched results or context notifications.
@MainActor
final class WorkspaceCatalogUseCase {
    private let repository: WorkspaceCatalogProviding

    init(repository: WorkspaceCatalogProviding) { self.repository = repository }

    func snapshot() throws -> WorkspaceSnapshot { try repository.readWorkspace() }
    func changes() -> AsyncStream<Void> { repository.workspaceChanges() }
}
