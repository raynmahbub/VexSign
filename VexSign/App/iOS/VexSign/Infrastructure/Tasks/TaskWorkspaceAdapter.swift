import Foundation
import Combine
import UIKit

/// Task/history/recovery actions remain owned by their original managers. IDs
/// are re-resolved at invocation; a row snapshot is not a mutable work handle.
@MainActor
final class TaskWorkspaceAdapter: TaskWorkspaceProviding {
    private let center: UnifiedTaskCenter
    private let downloads: DownloadManager
    private struct Removed {
        let token: UUID
        let task: UnifiedTask
        let deadline: ContinuousClock.Instant
    }
    private var removed: [String: Removed] = [:]
    private var icons: [String: Data] = [:]
    init(center: UnifiedTaskCenter, downloads: DownloadManager) { self.center = center; self.downloads = downloads }
    func state() -> TaskWorkspaceState {
        TaskWorkspaceState(tasks: center.tasks.map(record), history: center.history.map(record),
            historyPersistenceIssue: center.historyPersistenceIssue,
            interruptedDownloads: downloads.interruptedDownloads.map { item in
                InterruptedDownloadRecord(id: item.id, name: item.name, updatedAt: item.updatedAt,
                    stagedFile: downloads.recoveryJournal?.stagedFile(for: item, in: FileManager.default.downloadStaging),
                    canReverify: item.canReverify, hasLibraryCommit: item.libraryUUID != nil,
                    canDownload: item.sourceURL != nil, resumeSuggested: item.stage == .downloading)
            }, recoveryWarning: downloads.recoveryWarning)
    }
    func changes() -> AsyncStream<TaskWorkspaceState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(state())
            let subscription = center.objectWillChange.merge(with: downloads.objectWillChange).sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    continuation.yield(self.state())
                }
            }
            let observation = StreamObservationCancellation(subscription)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
    private func record(_ task: UnifiedTask) -> TaskRecord {
        TaskRecord(id: task.id, kind: task.kind, title: task.title, subtitle: task.subtitle, phase: task.phase,
            progress: task.progress, failureStage: task.failureStage, errorText: task.errorText,
            createdAt: task.createdAt, updatedAt: task.updatedAt, subjectID: task.subjectID,
            artifactID: task.context?.artifactID, signingTrace: task.context?.signingTrace,
            displayPhaseTitle: task.displayPhaseTitle, queryText: task.queryText,
            receipt: TaskReceipt.report(for: task), outcome: TaskReceipt.outcome(for: task),
            outcomeUnknown: TaskReceipt.evidence(for: task).isOutcomeUnknown, canRetry: center.canRetry(task))
    }
    func iconData(taskID: String) -> Data? {
        guard let task = (center.tasks + center.history).first(where: { $0.id == taskID }) else { return nil }
        if let data = icons[taskID] { return data }
        guard let data = center.historyIcon(for: task)?.pngData() else { return nil }
        icons[taskID] = data
        return data
    }
    func retry(taskID: String, allowingUnconfirmedInstall: Bool) -> Bool {
        guard let task = (center.tasks + center.history).first(where: { $0.id == taskID }),
              task.kind != .install || !TaskReceipt.evidence(for: task).isOutcomeUnknown || allowingUnconfirmedInstall else { return false }
        return center.retry(task)
    }
    func removeHistory(taskID: String) -> Bool {
        guard let task = center.history.first(where: { $0.id == taskID }), center.removeFromHistory(id: taskID) else { return false }
        let token = UUID()
        removed[taskID] = Removed(token: token, task: task, deadline: ContinuousClock().now.advanced(by: .seconds(6)))
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, self.removed[taskID]?.token == token else { return }
            self.removed.removeValue(forKey: taskID)
            self.icons.removeValue(forKey: taskID)
        }
        return true
    }
    func restoreHistory(taskID: String) -> Bool {
        guard let offer = removed[taskID], ContinuousClock().now < offer.deadline else {
            removed.removeValue(forKey: taskID)
            return false
        }
        guard center.restoreToHistory(offer.task) else { return false }
        removed.removeValue(forKey: taskID)
        return true
    }
    func clearHistory() { removed.removeAll(); icons.removeAll(); center.clearHistory() }
    func reverifyDownload(id: UUID) {
        guard let record = downloads.interruptedDownloads.first(where: { $0.id == id }) else { return }
        downloads.reverifyRecovery(record)
    }
    func retryDownload(id: UUID) {
        guard let record = downloads.interruptedDownloads.first(where: { $0.id == id }) else { return }
        downloads.retryRecoveryDownload(record)
    }
    func forgetDownload(id: UUID) {
        guard let record = downloads.interruptedDownloads.first(where: { $0.id == id }) else { return }
        downloads.forgetRecovery(record)
    }
}
