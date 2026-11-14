import Foundation
import Combine
import AltSourceKit

/// Rendering state over the Application catalog contract. Network, cache, decoding,
/// background execution and persistence remain with the single catalog owner.
@MainActor
final class SourcesViewModel: ObservableObject {
    @Published private(set) var isFinished = true
    @Published private(set) var sources: [RepositoryRecord: ASRepository] = [:]
    @Published private(set) var staleSourceIDs: Set<String> = []
    @Published private(set) var error: String?
    private let useCase: RepositoryCatalogUseCase<ASRepository>
    private var observation: Task<Void, Never>?

    init(useCase: RepositoryCatalogUseCase<ASRepository>) {
        self.useCase = useCase
        apply(useCase.state())
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await state in changes {
                guard !Task.isCancelled, let self else { break }
                self.apply(state)
            }
        }
    }
    deinit { observation?.cancel() }

    func fetchSources(_ sources: [RepositoryRecord], refresh: Bool = false, batchSize: Int = 4, configuredSources: [RepositoryRecord]? = nil) async {
        do {
            try await useCase.refresh(sources, force: refresh, batchSize: batchSize, configured: configuredSources)
            apply(useCase.state())
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func evictDeletedSources(valid sources: [RepositoryRecord]) {
        do { try useCase.retainConfiguredSources(sources); apply(useCase.state()) }
        catch { error = error.localizedDescription }
    }
    func resetLoadingState() { useCase.resetLoadingState(); apply(useCase.state()) }
    func isStale(_ source: RepositoryRecord) -> Bool {
        staleSourceIDs.contains(source.identifier ?? source.sourceURL?.absoluteString ?? source.id)
    }
    private func apply(_ state: RepositoryCatalogState<ASRepository>) {
        sources = state.catalogs
        isFinished = state.isFinished
        staleSourceIDs = state.staleSourceIDs
    }
}
