import Foundation
import Combine

@MainActor
final class InstallationQueueModel: ObservableObject {
    @Published private(set) var state: InstallationQueueState = .empty
    @Published private(set) var loadError: String?
    private let useCase: ObserveInstallationQueueUseCase
    private var observation: Task<Void, Never>?
    init(useCase: ObserveInstallationQueueUseCase) {
        self.useCase = useCase
        apply(Result { try useCase.state() })
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await state in changes {
                guard !Task.isCancelled, let self else { break }
                self.apply(state)
            }
        }
    }
    deinit { observation?.cancel() }
    var current: InstallationQueueEntry? { state.current }
    var upcoming: [InstallationQueueEntry] { state.upcoming }
    var installedApps: [InstallationQueueEntry] { state.installedApps }
    var installer: InstallationSessionState? { state.installer }
    var index: Int { state.index }
    var isFinished: Bool { state.isFinished }
    var isPaused: Bool { state.isPaused }
    var failurePresentation: InstallationFailure? { state.failure }
    var hasFailure: Bool { state.failure != nil }
    var succeededCount: Int { state.succeededCount }
    var failedCount: Int { state.failedCount }
    var latestReport: String? { state.latestReport }
    var currentTaskID: String? { state.currentTaskID }
    var showsPill: Bool { current != nil && !isSheetPresented && !isFinished }
    var isSheetPresented: Bool {
        get { state.isSheetPresented }
        set { state.isSheetPresented = newValue; useCase.setPresented(newValue) }
    }
    func sheetDismissed() { useCase.sheetDismissed() }
    func activate() { useCase.activate() }
    func pause() { useCase.pause() }
    func resume() { useCase.resume() }
    func clear() { useCase.clear() }
    func skip(forEntryID id: String? = nil) { useCase.skip(entryID: id) }
    func retryCurrent(entryID: String?, useLocalhost: Bool = false, afterManualDeviceCheck: Bool = false) {
        useCase.retry(entryID: entryID, useLocalhost: useLocalhost, afterManualDeviceCheck: afterManualDeviceCheck)
    }
    func stopAfterFailure() { useCase.stopAfterFailure() }
    func setFallbackPresented(_ presented: Bool) { useCase.setFallbackPresented(presented) }
    private func apply(_ result: Result<InstallationQueueState, Error>) {
        switch result {
        case .success(let state): self.state = state; loadError = nil
        case .failure(let error): loadError = error.localizedDescription
        }
    }
}
