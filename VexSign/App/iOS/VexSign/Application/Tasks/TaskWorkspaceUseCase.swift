import Foundation

@MainActor
final class TaskWorkspaceUseCase {
    private let provider: TaskWorkspaceProviding
    init(provider: TaskWorkspaceProviding) { self.provider = provider }
    func state() -> TaskWorkspaceState { provider.state() }
    func changes() -> AsyncStream<TaskWorkspaceState> { provider.changes() }
    func iconData(taskID: String) -> Data? { provider.iconData(taskID: taskID) }
    func retry(_ record: TaskRecord, allowingUnconfirmedInstall: Bool = false) -> Bool {
        // Repeat installation after handoff requires a separate explicit decision.
        guard record.kind != .install || !record.outcomeUnknown || allowingUnconfirmedInstall else { return false }
        return provider.retry(taskID: record.id, allowingUnconfirmedInstall: allowingUnconfirmedInstall)
    }
    func removeHistory(taskID: String) -> Bool { provider.removeHistory(taskID: taskID) }
    func restoreHistory(taskID: String) -> Bool { provider.restoreHistory(taskID: taskID) }
    func clearHistory() { provider.clearHistory() }
    func reverifyDownload(id: UUID) { provider.reverifyDownload(id: id) }
    func retryDownload(id: UUID) { provider.retryDownload(id: id) }
    func forgetDownload(id: UUID) { provider.forgetDownload(id: id) }

    static func signingTrace(in state: TaskWorkspaceState, subjectID: String?) -> TaskSigningTrace? {
        guard let subjectID, !subjectID.isEmpty else { return nil }
        let trace = (state.tasks + state.history).filter { $0.kind == .sign && $0.subjectID == subjectID }
            .max { $0.updatedAt < $1.updatedAt }?.signingTrace
        return trace?.isEmpty == false ? trace : nil
    }
    static func signingRecords(in state: TaskWorkspaceState, copyID: String?) -> SigningRecordIdentity.Selection<TaskRecord> {
        SigningRecordIdentity.select(copyID: copyID, from: (state.tasks + state.history).filter { $0.kind == .sign }.map {
            SigningRecordIdentity.Entry(record: $0, sourceID: $0.subjectID, artifactID: $0.artifactID,
                updatedAt: $0.updatedAt, completed: $0.phase == .completed)
        })
    }
}
