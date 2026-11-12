//
//  UnifiedTaskIntrospection.swift
//  VexSign
//
//  UI introspection helpers for the unified task center.
//

import Foundation
import NimbleExtensions

extension UnifiedTaskCenter {
    // MARK: - Introspection for UI

    var activeTasks: [UnifiedTask] {
        tasks.filter { $0.phase.isInProgress }
    }

    var failedTasks: [UnifiedTask] {
        tasks.filter { $0.phase == .failed }
    }

    var hasActivity: Bool {
        !activeTasks.isEmpty
    }

    /// The newest signing record started from one library app, in flight or long finished.
    ///
    /// `subjectID` is the app the run was started for; `context.artifactID` is the bundle it
    /// produced, which is always a different library record. This lookup is therefore about the
    /// source of a run - what the signing sheet resumes from. A screen that describes a copy
    /// itself uses `signingRecords(forCopy:)`.
    func latestSigningTask(subjectID: String?) -> UnifiedTask? {
        guard let subjectID, !subjectID.isEmpty else { return nil }
        return (tasks + history)
            .filter { $0.kind == .sign && $0.subjectID == subjectID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// The persisted execution trace of that run, or nil when nothing was recorded.
    func signingTrace(subjectID: String?) -> TaskSigningTrace? {
        guard let trace = latestSigningTask(subjectID: subjectID)?.context?.signingTrace else { return nil }
        return trace.isEmpty ? nil : trace
    }

    /// What is on record for one library copy: the run that produced it, and the newest run
    /// started from it.
    ///
    /// `latestSigningTask(subjectID:)` answers "what was last started from this copy", which is
    /// what the signing sheet wants. It is the wrong answer to "how was this copy signed": a
    /// re-sign that failed was started from the copy and never changed it. Screens that describe
    /// the copy itself ask here, so the two cannot be confused. See `SigningRecordIdentity`.
    func signingRecords(forCopy copyID: String?) -> SigningRecordIdentity.Selection<UnifiedTask> {
        let runs = (tasks + history).filter { $0.kind == .sign }
        return SigningRecordIdentity.select(
            copyID: copyID,
            from: runs.map { task in
                SigningRecordIdentity.Entry(
                    record: task,
                    sourceID: task.subjectID,
                    artifactID: task.context?.artifactID,
                    updatedAt: task.updatedAt,
                    completed: task.phase == .completed
                )
            }
        )
    }
}