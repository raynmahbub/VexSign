import Foundation
import Combine

@MainActor
final class TaskWorkspaceModel: ObservableObject {
    @Published private(set) var state: TaskWorkspaceState
    private let useCase: TaskWorkspaceUseCase
    private var observation: Task<Void, Never>?
    init(useCase: TaskWorkspaceUseCase) {
        self.useCase = useCase; state = useCase.state()
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await state in changes {
                guard !Task.isCancelled, let self else { break }
                self.state = state
            }
        }
    }
    deinit { observation?.cancel() }
    var tasks: [TaskRecord] { state.tasks }
    var history: [TaskRecord] { state.history }
    var historyPersistenceIssue: TaskHistoryIssue? { state.historyPersistenceIssue }
    var interruptedDownloads: [InterruptedDownloadRecord] { state.interruptedDownloads }
    var recoveryWarning: String? { state.recoveryWarning }
    func iconData(for task: TaskRecord) -> Data? { useCase.iconData(taskID: task.id) }
    func canRetry(_ task: TaskRecord) -> Bool { task.canRetry }
    @discardableResult func retry(_ task: TaskRecord, allowingUnconfirmedInstall: Bool = false) -> Bool {
        defer { refresh() }; return useCase.retry(task, allowingUnconfirmedInstall: allowingUnconfirmedInstall)
    }
    @discardableResult func removeFromHistory(id: String) -> Bool {
        defer { refresh() }; return useCase.removeHistory(taskID: id)
    }
    @discardableResult func restoreToHistory(_ task: TaskRecord) -> Bool {
        defer { refresh() }; return useCase.restoreHistory(taskID: task.id)
    }
    func clearHistory() { useCase.clearHistory(); refresh() }
    func reverifyRecovery(_ item: InterruptedDownloadRecord) { useCase.reverifyDownload(id: item.id); refresh() }
    func retryRecoveryDownload(_ item: InterruptedDownloadRecord) { useCase.retryDownload(id: item.id); refresh() }
    func forgetRecovery(_ item: InterruptedDownloadRecord) { useCase.forgetDownload(id: item.id); refresh() }
    func signingTrace(subjectID: String?) -> TaskSigningTrace? { TaskWorkspaceUseCase.signingTrace(in: state, subjectID: subjectID) }
    func signingRecords(forCopy copyID: String?) -> SigningRecordIdentity.Selection<TaskRecord> {
        TaskWorkspaceUseCase.signingRecords(in: state, copyID: copyID)
    }
    private func refresh() { state = useCase.state() }
}
