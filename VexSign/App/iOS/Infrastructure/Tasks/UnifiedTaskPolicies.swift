//
//  UnifiedTaskPolicies.swift
//  VexSign
//
//  Three rules that were implicit in `UnifiedTaskCenter` and therefore unenforceable.
//
//  The center already had one transition authority — `UnifiedTask.move(to:)` consults
//  `canTransition(to:kind:)` and refuses to leave a terminal phase. Progress, retry and
//  submission had no such rule:
//
//    * `update(_:progress:)` wrote whatever a caller passed, so a late callback from an
//      abandoned stage could drag the bar backwards or past 100%;
//    * `registerRetry`'s guard was a tautology (`!isTerminal || failed || cancelled || …`
//      is always true), so handlers were registered for running tasks and never released
//      when those tasks finished normally;
//    * `begin` inserted a record unconditionally, so a double tap produced two tasks for
//      one operation.
//
//  They live here as pure functions so the rules can be asserted without a center, a
//  main actor or a persisted journal.
//

import Foundation

// MARK: - Progress

enum TaskProgressRule {
    /// Progress outside `0...1` is a caller bug; the UI must not inherit it. Negative is the
    /// documented "indeterminate" value, so it is preserved rather than clamped to zero.
    static func normalized(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        if value < 0 { return -1 }
        return min(value, 1)
    }

    /// The value a task may show after a progress report.
    ///
    /// Progress never moves backwards inside one stage: an operation that reports 60% and then
    /// 40% is telling us that something is wrong, not that it went back in time, and a bar that
    /// visibly rewinds reads as a restart. A new stage may legitimately start lower — extraction
    /// after a download starts at its own zero — so a stage change resets the floor.
    static func next(previous: Double, proposed: Double, stageChanged: Bool) -> Double {
        let value = normalized(proposed)
        let current = normalized(previous)
        if value < 0 { return current < 0 ? -1 : current }
        if stageChanged { return value }
        if current < 0 { return value }
        return max(current, value)
    }

    /// A completed task is at 100%, whatever the last progress callback said.
    ///
    /// Terminal phases other than `completed` keep the value they had: a failure at 80% is more
    /// informative than resetting it to zero.
    static func final(phase: UnifiedTaskPhase, current: Double) -> Double {
        phase == .completed ? 1 : normalized(current)
    }
}

// MARK: - Retry

enum TaskRetryPolicy {
    /// A retry can only be offered where a new attempt is meaningful and safe.
    ///
    /// Never for a task that is still running: a second attempt would race the first one over the
    /// same artifact. `unconfirmed` is included because iOS sometimes cannot report an install
    /// that did happen, and the user — not the app — decides whether to try again.
    static func canOffer(_ phase: UnifiedTaskPhase) -> Bool {
        switch phase {
        case .failed, .cancelled, .unconfirmed: true
        default: false
        }
    }
}

// MARK: - Submission

enum TaskSubmissionPolicy {
    /// An in-flight task for the same operation, which a new request should not duplicate.
    ///
    /// Matching is by kind and subject (the app UUID, download identifier, …) because that pair is
    /// what identifies "this operation on this thing". A task without a subject is never treated
    /// as a duplicate: two anonymous signings are not provably the same operation.
    static func inFlight(kind: UnifiedTaskKind, subjectID: String?, in tasks: [UnifiedTask]) -> UnifiedTask? {
        guard let subjectID, !subjectID.isEmpty else { return nil }
        return tasks.first { $0.kind == kind && $0.subjectID == subjectID && !$0.phase.isTerminal }
    }

    /// A `queued` duplicate can be adopted by the caller, because nothing has started yet.
    ///
    /// Anything past `queued` is already doing work and must not be restarted; the caller
    /// receives the existing task reference instead of a second one.
    static func adoptable(kind: UnifiedTaskKind, subjectID: String?, in tasks: [UnifiedTask]) -> UnifiedTask? {
        guard let match = inFlight(kind: kind, subjectID: subjectID, in: tasks), match.phase == .queued else {
            return nil
        }
        return match
    }
}

// MARK: - Mirroring

enum TaskMirrorPolicy {
    /// The verdict for a mirrored download whose `Download` row has disappeared.
    ///
    /// `DownloadManager` drops the row on every path that did *not* finish: a non-recoverable
    /// transfer error, a package over the 8 GiB safety limit, and the user stopping the
    /// transfer. `Download` has no failure phase, so the absence of a row is the only signal the
    /// mirror receives — and it is not a success signal.
    ///
    /// The mirror used to read it as `.completed`, which put a green "Completed" in the Task
    /// Center and the Dynamic Island for a download that had just failed or been stopped, and
    /// released the retry handler on the way out. `interrupted` is what this side of the seam
    /// can defend: the transfer did not finish, and which of the three paths ended it is not
    /// recoverable from a missing row. A mirror that already reached a terminal phase keeps its
    /// verdict (returns `nil`), so a finished download is never relabelled by its own removal.
    static func vanished(_ phase: UnifiedTaskPhase) -> UnifiedTaskPhase? {
        phase.isTerminal ? nil : .interrupted
    }
}
