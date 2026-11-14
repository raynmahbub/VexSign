//
//  UnifiedTaskModels.swift
//  VexSign
//
//  Model types for the unified task pipeline.
//

import Foundation
import OSLog
import NimbleExtensions

// MARK: - Model

/// Stage-based suggestions, not a diagnosis. Never infer security decisions
/// from localized error text or recommend bypassing verification.

/// A single task. Reference type so in-place progress updates publish
/// through the center without diffing the whole list.
///
/// The unchecked conformance mirrors the existing `Download` model: instances
/// are created and mutated on the main actor, but references are handed
/// across actor boundaries by signing/install flows running off-main.
final class UnifiedTask: Identifiable, @unchecked Sendable {
	let id: String
	let kind: UnifiedTaskKind
	var title: String
	var subtitle: String?
	var phase: UnifiedTaskPhase
	/// 0…1; negative means "indeterminate".
	var progress: Double
	var failureStage: UnifiedTaskPhase?
	var errorText: String?
	/// Set at init; `var` only so history snapshots can be restored verbatim.
	var createdAt: Date
	var updatedAt: Date
	/// Identifies the originating flow (download id, app uuid, …) for retry.
	var subjectID: String?
    var context: TaskContext?
    var stageHistory: [TaskStageEntry]

    var displayPhaseTitle: String {
        if phase == .completed && kind == .sign { return UnifiedTaskPhase.signed.title }
        if phase == .completed && kind == .importIPA { return UnifiedTaskPhase.readyToSign.title }
        if phase == .completed && kind == .install,
           ["native-installation-completed", "device-confirmed-installed"].contains(context?.confirmationReason ?? "") {
            return .localized("Installed")
        }
        return phase.title
    }

	init(
		id: String = UUID().uuidString,
		kind: UnifiedTaskKind,
		title: String,
		subtitle: String? = nil,
		phase: UnifiedTaskPhase = .queued,
		progress: Double = 0,
		subjectID: String? = nil
	) {
		self.id = id
		self.kind = kind
		self.title = title
		self.subtitle = subtitle
		self.phase = phase
		self.progress = progress
		self.createdAt = Date()
		self.updatedAt = Date()
		self.subjectID = subjectID
        self.context = TaskContext()
        self.stageHistory = [.init(phase: phase, date: createdAt)]
	}

    func recoverAfterRestart(at date: Date = Date()) {
        guard !phase.isTerminal else { return }
        // A handed-off install may have continued while this process was absent.
        // Neither completion nor cancellation can be inferred on relaunch.
        let handedOff = kind == .install && context?.handoffAt != nil
        failureStage = handedOff ? nil : phase
        phase = handedOff ? .unconfirmed : .interrupted
        context?.monitoringActive = false
        updatedAt = max(updatedAt, date)
        stageHistory.append(.init(phase: phase, date: updatedAt))
        if stageHistory.count > 256 { stageHistory.removeFirst(stageHistory.count - 256) }
        context?.confirmationReason = handedOff ? "process-exit-installation-unconfirmed" : "interrupted-process-exit"
    }

    /// One transition authority for UI, persistence and receipts. Progress updates
    /// never establish success; only callers with an actual operation result do.
    @discardableResult
    func move(to next: UnifiedTaskPhase, at date: Date = Date()) -> Bool {
        guard phase.canTransition(to: next, kind: kind) else { return false }
        let timestamp = max(updatedAt, date)
        if phase != next {
            stageHistory.append(.init(phase: next, date: timestamp))
            if stageHistory.count > 256 { stageHistory.removeFirst(stageHistory.count - 256) }
        }
        if next == .failed { failureStage = phase }
        phase = next
        updatedAt = timestamp
        return true
    }

	/// Persistable snapshot for the history file.
	struct Snapshot: Codable {
		var id: String
		var kind: String
		var title: String
		var subtitle: String?
		var phase: String
		var failureStage: String?
		var errorText: String?
		var createdAt: Date
		var updatedAt: Date
		var subjectID: String?
        var context: TaskContext?
        var stageHistory: [TaskStageEntry]?
	}

	var snapshot: Snapshot {
		Snapshot(
			id: id,
			kind: kind.rawValue,
			title: title,
			subtitle: subtitle,
			phase: phase.rawValue,
			failureStage: failureStage?.rawValue,
			errorText: errorText,
			createdAt: createdAt,
			updatedAt: updatedAt,
			subjectID: subjectID,
            context: context,
            stageHistory: stageHistory
		)
	}

	static func from(_ snapshot: Snapshot) -> UnifiedTask {
		let task = UnifiedTask(
			id: snapshot.id,
			kind: UnifiedTaskKind(rawValue: snapshot.kind) ?? .download,
			title: snapshot.title,
			subtitle: snapshot.subtitle,
			phase: UnifiedTaskPhase(rawValue: snapshot.phase) ?? .interrupted,
			subjectID: snapshot.subjectID
		)
		task.failureStage = snapshot.failureStage.flatMap { UnifiedTaskPhase(rawValue: $0) }
		task.errorText = snapshot.errorText.map(LogRedaction.redact)
		task.createdAt = snapshot.createdAt
		task.updatedAt = snapshot.updatedAt
        task.context = snapshot.context
        task.stageHistory = snapshot.stageHistory ?? [.init(phase: task.phase, date: snapshot.updatedAt)]
		return task
	}
}

extension UnifiedTask: TaskQueryItem {
    var queryText: String {
        [title, subtitle ?? "", kind.title, phase.title, failureStage?.title ?? "", errorText ?? ""].joined(separator: " ")
    }
}
