//
//  UnifiedTaskCenter.swift
//  VexSign
//
//  One model for every long-running operation: downloads, imports, signing,
//  installations and updates. Each task moves through the same pipeline —
//
//      queued → downloading → extracting → signing → installing → completed
//                                    ↘ failed / cancelled (from any stage)
//
//  — so progress, failure stage, retry and history are consistent everywhere:
//  the Task Center UI, the Downloads tab and the Dynamic Island all read the
//  same state instead of three ad-hoc ones.
//
//  Downloads are mirrored from `DownloadManager` (which already models
//  download → import → sign phases); signing and installation flows report
//  in through `begin(...)`/`transition(...)` at their natural boundaries.
//  History persists the last 200 finished tasks as JSON; imported-app thumbnails
//  are kept separately on device. Neither store contains credentials or IPA contents.
//

import Foundation
import UIKit
import Combine
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

// MARK: - Center

@MainActor
final class UnifiedTaskCenter: ObservableObject {
	static let shared = UnifiedTaskCenter()

	/// In-flight (and very recently finished) tasks, newest first.
	@Published private(set) var tasks: [UnifiedTask] = []
	/// Persisted history of finished tasks, newest first.
	@Published private(set) var history: [UnifiedTask] = []

	/// Registered retry handlers (in-memory only — a retry needs the live flow).
	private let iconArchive = TaskIconArchive()
	private var retryHandlers: [String: () -> Void] = [:]
	private var downloadMirrors: [String: UnifiedTask] = [:]
	private var cancellables = Set<AnyCancellable>()

    @Published private(set) var historyPersistenceIssue: TaskHistoryJournal.Issue?
    private let historyJournal = TaskHistoryJournal(url: UnifiedTaskCenter.historyFileURL)
    private var historyLoaded = false
    private var historyLoading = false
    private var clearHistoryRequested = false

	private static let historyLimit = 200
	private static var historyFileURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		return base.appendingPathComponent("UnifiedTaskHistory.json")
	}

	private init() {
		_loadHistory()
		_mirrorDownloads()
        NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.historyLoaded { self._loadHistory() }
                else { self._persistHistory() }
            }
            .store(in: &cancellables)
	}

	// MARK: - Task lifecycle (explicit flows: sign, install, export, update)

	@discardableResult
	func begin(
		kind: UnifiedTaskKind,
		title: String,
		subtitle: String? = nil,
		phase: UnifiedTaskPhase = .queued,
        progress: Double = 0,
		subjectID: String? = nil
	) -> UnifiedTask {
		let task = UnifiedTask(kind: kind, title: title, subtitle: subtitle, phase: phase, progress: progress, subjectID: subjectID)
		tasks.insert(task, at: 0)
        _persistHistory()
		return task
	}

	func transition(_ task: UnifiedTask, to phase: UnifiedTaskPhase, progress: Double? = nil, error: String? = nil) {
        guard task.move(to: phase) else { return }
		if let progress { task.progress = progress }
		task.errorText = error.map(LogRedaction.redact)
        if phase == .failed, task.context?.confirmationReason == nil { task.context?.confirmationReason = "operation-failed" }
        if phase == .cancelled, task.context?.confirmationReason != "monitoring-stopped-install-may-continue" { task.context?.confirmationReason = "cancelled" }
		task.updatedAt = Date()
		if phase.isTerminal {
			_finalize(task)
		} else {
            _persistHistory()
			objectWillChange.send()
		}
	}

	func update(_ task: UnifiedTask, progress: Double) {
		guard !task.phase.isTerminal else { return }
		task.progress = progress
		task.updatedAt = Date()
		objectWillChange.send()
	}

	func cancel(_ task: UnifiedTask) {
		guard !task.phase.isTerminal else { return }
		transition(task, to: .cancelled)
	}

	func registerRetry(_ task: UnifiedTask, handler: @escaping () -> Void) {
		guard !task.phase.isTerminal || task.phase == .failed || task.phase == .cancelled
			|| task.phase == .unconfirmed else { return }
		retryHandlers[task.id] = handler
	}

    func canRetry(_ task: UnifiedTask) -> Bool {
        (task.phase == .failed || task.phase == .cancelled || task.phase == .unconfirmed)
			&& retryHandlers[task.id] != nil
    }

	/// Retry a failed/cancelled task when its flow registered a handler.
	/// Returns false when no live handler exists (e.g. after a relaunch).
	@discardableResult
	func retry(_ task: UnifiedTask) -> Bool {
		guard canRetry(task), let handler = retryHandlers[task.id] else { return false }
        retryHandlers.removeValue(forKey: task.id)
        // Resumed downloads receive a fresh mirror too, not a terminal record
        // whose progress would be silently ignored.
        let mirrorIDs = downloadMirrors.filter { $0.value.id == task.id }.map(\.key)
        for id in mirrorIDs { downloadMirrors.removeValue(forKey: id) }
		handler()
		return true
	}

	/// The exact stage a task failed at, for "show exact failure stage".
	var failureDescription: String {
		let failed = (tasks + history).filter { $0.phase == .failed }
		guard let latest = failed.first else { return "" }
		if let stage = latest.failureStage {
			return String.localized("Failed at %@: %@", arguments: stage.title, latest.errorText ?? .localized("Unknown error"))
		}
		return latest.errorText ?? .localized("Unknown error")
	}

	private func _finalize(_ task: UnifiedTask) {
		if let index = tasks.firstIndex(where: { $0.id == task.id }) {
			tasks.remove(at: index)
		}
		history.insert(task, at: 0)
		if history.count > Self.historyLimit {
			history = Array(history.prefix(Self.historyLimit))
		}
		_persistHistory()
	}

	// MARK: - Download mirroring

	/// Downloads, imports and their signing phase already live in
	/// `DownloadManager`; mirroring them keeps one source of truth while the
	/// task center presents the unified pipeline.
	private func _mirrorDownloads() {
		DownloadManager.shared.$downloads
			.receive(on: RunLoop.main)
			.sink { [weak self] downloads in
				self?._syncMirrored(downloads: downloads)
			}
			.store(in: &cancellables)
	}

	private func _syncMirrored(downloads: [Download]) {
		let activeIDs = Set(downloads.map { $0.id })

		// Drop mirrors whose download disappeared without a terminal phase.
		for (downloadID, task) in downloadMirrors where !activeIDs.contains(downloadID) {
			if !task.phase.isTerminal {
				task.phase = .completed
				_finalize(task)
			}
			downloadMirrors.removeValue(forKey: downloadID)
		}

		for download in downloads {
			let task: UnifiedTask
			if let existing = downloadMirrors[download.id] {
				task = existing
			} else {
				let isArchive = download.onlyArchiving
				task = begin(
					kind: isArchive ? .importIPA : .download,
					title: download.fileName,
					subtitle: download.appDescription,
					phase: .queued,
					subjectID: download.id
				)
				registerRetry(task) { [weak download] in
					guard let download else { return }
					if let resumeData = download.resumeData, !resumeData.isEmpty {
						DownloadManager.shared.resumeDownload(download)
					}
				}
				downloadMirrors[download.id] = task
			}

			// Map the download's phase onto the unified pipeline.
			let newPhase: UnifiedTaskPhase
			switch download.phase {
			case .queued: newPhase = .queued
			case .downloading: newPhase = .downloading
			case .paused: newPhase = .paused
			case .verifying, .importing: newPhase = .importing
			case .signing: newPhase = .signing
			case .completed: newPhase = .completed
			}

			if newPhase.isTerminal {
				if !task.phase.isTerminal {
                    if task.kind == .importIPA { transition(task, to: .readyToSign) }
					transition(task, to: .completed)
				}
			} else if task.phase != newPhase {
				transition(task, to: newPhase, progress: download.phaseProgress)
			} else {
				update(task, progress: download.phaseProgress)
			}
		}
	}

    func recordImportedArtifact(_ app: AppInfoPresentable, task: UnifiedTask?, downloadID: String?) {
        _syncMirrored(downloads: DownloadManager.shared.downloads)
        guard let record = task ?? (tasks + history).first(where: { $0.subjectID == downloadID && downloadID != nil }) else { return }
        var context = record.context ?? TaskContext()
        context.artifactID = app.uuid
        context.appVersion = TaskContext.versionToken(app.version)
        if let directory = Storage.shared.getAppDirectory(for: app),
           let info = NSDictionary(contentsOf: directory.appendingPathComponent("Info.plist")) {
            context.appBuild = TaskContext.versionToken(info["CFBundleVersion"] as? String)
        }
        context.confirmationReason = "import-registered"
        record.context = context
        transition(record, to: .readyToSign)
        if task != nil { transition(record, to: .completed, progress: 1) }
    }

    func historyIcon(for task: UnifiedTask) -> UIImage? { iconArchive.image(for: task.id) }

    func captureHistoryIcon(_ image: UIImage, subjectID: String) {
        // The center can be initialized lazily by the first completed import.
        // Materialize its mirror before storing that import's thumbnail.
        _syncMirrored(downloads: DownloadManager.shared.downloads)
        guard let task = (tasks + history).first(where: { $0.subjectID == subjectID }) else { return }
        do {
            try iconArchive.store(image, for: task.id)
            objectWillChange.send()
        } catch {
            Logger.misc.warning("Could not save task thumbnail: \(error.localizedDescription)")
        }
    }

    private func pruneHistoryIcons() {
        do { try iconArchive.prune(keeping: Set((tasks + history).map(\.id))) }
        catch { Logger.misc.warning("Could not prune task thumbnails: \(error.localizedDescription)") }
    }

	// MARK: - Persistence

private func _loadHistory() {
        guard !historyLoading, !historyLoaded else { return }
        historyLoading = true
        
        Task { [weak self] in
            guard let self else { return }
            let result = await self.historyJournal.load()
            await MainActor.run {
                self.historyLoading = false
                switch result {
                case .blocked(let issue):
                    self.historyPersistenceIssue = issue
                    Logger.misc.warning("Task history unavailable; original retained and writes blocked.")
                case .loaded(let snapshots, let warning):
                    self.historyLoaded = true
                    self.historyPersistenceIssue = warning
                    if warning != nil {
                        Logger.misc.warning("Unreadable task history preserved in a recovery file.")
                    }
                    if !self.clearHistoryRequested {
                        // Live work may have started while disk IO was running.
                        let liveIDs = Set((self.tasks + self.history).map(\.id))
                        let recovered = snapshots.filter { !liveIDs.contains($0.id) }.map {
                            let task = UnifiedTask.from($0)
                            task.recoverAfterRestart()
                            return task
                        }
                        self.history = Array((self.history + recovered)
                            .sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.historyLimit))
                    }
                    self.clearHistoryRequested = false
                    self._persistHistory()
                }
            }
        }
    }

private func _persistHistory() {
        guard historyLoaded else {
            // Retry unavailable reads on subsequent activity or device unlock.
            // Never replace a journal we have not successfully read/preserved.
            _loadHistory()
            return
        }
        pruneHistoryIcons()
        // Capture values on the main actor; no mutable UnifiedTask crosses to IO.
        let snapshots = (tasks + history).map { $0.snapshot }
        
        Task { [weak self] in
            guard let self else { return }
            let issue = await self.historyJournal.save(snapshots)
            await MainActor.run {
                if let issue {
                    self.historyPersistenceIssue = issue
                    Logger.misc.warning("Task history write failed; prior atomic journal retained.")
                } else if self.historyPersistenceIssue == .writeFailed {
                    self.historyPersistenceIssue = nil
                }
            }
        }
    }

	/// Clears the persisted history (Settings → Diagnostics).
	func clearHistory() {
        clearHistoryRequested = !historyLoaded
        history = []
        _persistHistory()
		objectWillChange.send()
	}

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
