import Foundation
import Combine

/// Immutable snapshots replace Core Data objects throughout the view tree. A failed
/// refresh retains the last good snapshot and surfaces an error, never a fake empty store.
@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published private(set) var snapshot = WorkspaceSnapshot.empty
    @Published private(set) var loadError: String?
    @Published private(set) var revision = 0
    private let useCase: WorkspaceCatalogUseCase
    private var observation: Task<Void, Never>?

    init(useCase: WorkspaceCatalogUseCase) {
        self.useCase = useCase
        refresh()
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { break }
                self.refresh()
            }
        }
    }

    deinit { observation?.cancel() }

    func refresh() {
        do {
            snapshot = try useCase.snapshot()
            loadError = nil
            revision &+= 1
        } catch {
            loadError = error.localizedDescription
        }
    }
}
