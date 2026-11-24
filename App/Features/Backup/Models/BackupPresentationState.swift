import Foundation

/// Admission for this screen's callbacks, not a backup/restore engine. A later
/// operation or a disappeared screen retires every callback from the old offer,
/// including delayed completion alerts and their Restart action.
struct BackupPresentationState {
    struct RestoreCompletion {
        let generation: UUID
        let summary: BackupRestoreSummary
    }

    private(set) var isVisible = false
    private var generation: UUID?
    private var completedRestore: UUID?
    private var restoreCompletion: RestoreCompletion?

    mutating func appear() {
        guard !isVisible else { return }
        isVisible = true
        generation = UUID()
        completedRestore = nil
        restoreCompletion = nil
    }

    mutating func disappear() {
        isVisible = false
        generation = nil
        completedRestore = nil
        restoreCompletion = nil
    }

    mutating func beginOperation() -> UUID? {
        guard isVisible else { return nil }
        let attempt = UUID()
        generation = attempt
        completedRestore = nil
        restoreCompletion = nil
        return attempt
    }

    func isCurrent(_ attempt: UUID) -> Bool {
        isVisible && generation == attempt
    }

    @discardableResult
    mutating func completeRestore(_ summary: BackupRestoreSummary, for attempt: UUID) -> Bool {
        guard isCurrent(attempt), completedRestore != attempt else { return false }
        completedRestore = attempt
        restoreCompletion = RestoreCompletion(generation: attempt, summary: summary)
        return true
    }

    /// The sheet's dismissal and the delayed task may both try to present. Only
    /// one can consume this completion, and neither can revive a retired run.
    mutating func takeRestoreCompletion() -> RestoreCompletion? {
        guard let completion = restoreCompletion else { return nil }
        restoreCompletion = nil
        guard isCurrent(completion.generation) else { return nil }
        return completion
    }
}
