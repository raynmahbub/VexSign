import Foundation
import UIKit
import Combine

@MainActor
final class BatchWorkflowModel: ObservableObject {
    @Published private(set) var state: BatchSigningState
    @Published private(set) var error: String?
    let mode: BatchSigningMode
    private let useCase: BatchSigningUseCase<UIImage>
    private var observation: Task<Void, Never>?
    init(useCase: BatchSigningUseCase<UIImage>, mode: BatchSigningMode) throws {
        self.useCase = useCase; self.mode = mode
        self.state = try useCase.state()
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await result in changes {
                guard !Task.isCancelled, let self else { break }
                self.apply(result)
            }
        }
    }
    deinit { observation?.cancel() }
    var items: [BatchSigningItem] { state.items }
    var phase: BatchSigningPhase { state.phase }
    var currentIndex: Int { state.currentIndex }
    var currentInstaller: InstallationSessionState? { state.currentInstaller }
    var isCancelled: Bool { state.isCancelled }
    var isFinished: Bool { phase == .finished }
    var succeeded: Int {
        items.filter {
            switch $0.state {
            case .installed: true
            case .signed, .alreadySigned: !mode.installs
            default: false
            }
        }.count
    }
    var unconfirmed: Int { items.filter { $0.state == .unconfirmed }.count }
    var failed: Int { items.filter { if case .failed = $0.state { return true }; return false }.count }
    func run() async { await useCase.run(); apply(Result { try useCase.state() }) }
    func cancel() { useCase.cancel(); apply(Result { try useCase.state() }) }
    func skipCurrentInstall() { useCase.skipCurrentInstall() }
    func setFallbackPresented(_ presented: Bool) { useCase.setFallbackPresented(presented) }
    private func apply(_ result: Result<BatchSigningState, Error>) {
        switch result {
        case .success(let state): self.state = state; error = nil
        case .failure(let error): self.error = error.localizedDescription
        }
    }
}
