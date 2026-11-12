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

enum UnifiedTaskKind: String, Codable, CaseIterable {
	case download
	case importIPA = "import"
	case sign
	case install
	case update
	case export

	var title: String {
		switch self {
		case .download: .localized("Download")
		case .importIPA: .localized("Import")
		case .sign: .localized("Sign")
		case .install: .localized("Install")
		case .update: .localized("Update")
		case .export: .localized("Export")
		}
	}

	var icon: String {
		switch self {
		case .download: "arrow.down.circle.fill"
		case .importIPA: "square.and.arrow.down.fill"
		case .sign: "signature"
		case .install: "iphone.badge.plus"
		case .update: "arrow.triangle.2.circlepath"
		case .export: "square.and.arrow.up.fill"
		}
	}
}

enum UnifiedTaskPhase: String, Codable, CaseIterable, Sendable {
	case queued
	case downloading
	case extracting
    case importing, readyToSign, signed, preparingInstallation, waitingForIOS, verifying
	case signing
	case installing
	case completed
	case failed
	case cancelled
    case interrupted
	/// VexSign finished, but iOS never exposed enough evidence to say whether the
	/// app was installed. Not a success claim and not a failure: private
	/// LaunchServices lookups are filtered on modern iOS, so an install that
	/// worked can be unobservable. Reporting that as "Failed" told users to retry
	/// an app that was already on their Home Screen.
	case unconfirmed

	/// Paused is a sub-state of downloading surfaced by the task center.
	case paused

	var title: String {
		switch self {
        case .importing: .localized("Importing")
        case .readyToSign: .localized("Ready to sign")
        case .signed: .localized("Signed")
        case .preparingInstallation: .localized("Preparing installation")
        case .waitingForIOS: .localized("Waiting for iOS confirmation")
        case .verifying: .localized("Verifying installation")
		case .queued: .localized("Queued")
		case .downloading: .localized("Downloading")
		case .extracting: .localized("Extracting")
		case .signing: .localized("Signing")
		case .installing: .localized("Installing")
		case .completed: .localized("Completed")
		case .failed: .localized("Failed")
		case .cancelled: .localized("Cancelled")
        case .interrupted: .localized("Interrupted")
		case .unconfirmed: .localized("Not confirmed")
		case .paused: .localized("Paused")
		}
	}

    /// Separate operations share one vocabulary, not one success verdict.
    /// Queue installs can start a new item at preparation after verification.
    func canTransition(to next: Self, kind: UnifiedTaskKind) -> Bool {
        guard !isTerminal else { return false }
        if kind == .sign {
            if next == .failed || next == .cancelled || next == self { return true }
            switch self {
            case .queued, .readyToSign: return next == .signing
            case .signing: return next == .signed || next == .completed
            case .signed: return next == .completed
            default: return false
            }
        }
        if kind == .install {
            if next == self || next == .failed || next == .cancelled || next == .unconfirmed { return true }
            switch self {
            case .queued: return next == .preparingInstallation
            case .preparingInstallation: return next == .waitingForIOS || next == .installing
            case .waitingForIOS: return next == .installing || next == .verifying
            case .installing: return next == .verifying || next == .completed
            case .verifying: return next == .completed
            default: return false
            }
        }
        return true
    }

	var isTerminal: Bool {
		self == .completed || self == .failed || self == .cancelled || self == .interrupted
			|| self == .unconfirmed
	}

	var isInProgress: Bool { !isTerminal }
}

/// Stage-based suggestions, not a diagnosis. Never infer security decisions
/// from localized error text or recommend bypassing verification.
enum TaskRecoveryGuide: Equatable {
    case download, archive, signing, installation, general

    static func resolve(kind: UnifiedTaskKind, failureStage: UnifiedTaskPhase?) -> Self {
        switch failureStage {
        case .downloading: return .download
        case .extracting, .importing, .readyToSign: return .archive
        case .signing: return .signing
        case .installing, .preparingInstallation, .waitingForIOS, .verifying: return .installation
        default:
            switch kind {
            case .download: return .download
            case .importIPA: return .archive
            case .sign: return .signing
            case .install: return .installation
            case .update, .export: return .general
            }
        }
    }

    var detail: String {
        switch self {
        case .download:
            return .localized("Check connectivity, available storage and download conditions. Confirm the source still provides the file before retrying.")
        case .archive:
            return .localized("Download a fresh IPA from a trusted source and check available storage. Unsafe paths, unsupported links or a corrupt archive must be fixed at the source; do not disable archive validation.")
        case .signing:
            return .localized("Review certificate expiry, provisioning-profile scope, entitlements and injected tweaks. Use Activity Logs to identify the failing step before retrying.")
        case .installation:
            return .localized("Review the selected installation method. Local HTTPS needs device trust and connectivity; idevice needs a valid pairing file and running VPN. Signing success alone does not prove installation succeeded.")
        case .general:
            return .localized("Review the recorded failure stage and Activity Logs, then restart the action from its original screen if retry is unavailable.")
        }
    }
}

/// A single task. Reference type so in-place progress updates publish
/// through the center without diffing the whole list.
///
/// `@unchecked Sendable` mirrors the existing `Download` model: instances
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