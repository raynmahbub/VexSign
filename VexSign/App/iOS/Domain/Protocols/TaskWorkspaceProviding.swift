import Foundation

/// Immutable UI metadata, captured on the task owner's actor. No mutable task,
/// persistence journal, download handle or retry closure escapes the adapter.
struct TaskRecord: Identifiable, TaskQueryItem, Sendable {
    let id: String
    let kind: UnifiedTaskKind
    let title: String
    let subtitle: String?
    let phase: UnifiedTaskPhase
    let progress: Double
    let failureStage: UnifiedTaskPhase?
    let errorText: String?
    let createdAt: Date
    let updatedAt: Date
    let subjectID: String?
    let artifactID: String?
    let signingTrace: TaskSigningTrace?
    let displayPhaseTitle: String
    let queryText: String
    let receipt: String
    let outcome: String
    let outcomeUnknown: Bool
    let canRetry: Bool
}
struct InterruptedDownloadRecord: Identifiable, Sendable {
    let id: UUID
    let name: String
    let updatedAt: Date
    let stagedFile: URL?
    let canReverify: Bool
    let hasLibraryCommit: Bool
    let canDownload: Bool
    let resumeSuggested: Bool
}
struct TaskWorkspaceState: Sendable {
    var tasks: [TaskRecord] = []
    var history: [TaskRecord] = []
    var historyPersistenceIssue: TaskHistoryIssue?
    var interruptedDownloads: [InterruptedDownloadRecord] = []
    var recoveryWarning: String?
}

@MainActor
protocol TaskWorkspaceProviding: AnyObject {
    func state() -> TaskWorkspaceState
    func changes() -> AsyncStream<TaskWorkspaceState>
    func iconData(taskID: String) -> Data?
    func retry(taskID: String, allowingUnconfirmedInstall: Bool) -> Bool
    func removeHistory(taskID: String) -> Bool
    func restoreHistory(taskID: String) -> Bool
    func clearHistory()
    func reverifyDownload(id: UUID)
    func retryDownload(id: UUID)
    func forgetDownload(id: UUID)
}
