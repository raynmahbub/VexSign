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

// MARK: - Center

@MainActor
final class UnifiedTaskCenter: ObservableObject {
	static let shared = UnifiedTaskCenter()

	/// In-flight (and very recently finished) tasks, newest first.
	@Published private(set) var tasks: [UnifiedTask] = []
	/// Persisted history of finished tasks, newest first.
	@Published private(set) var history: [UnifiedTask] = []

	/// Registered retry handlers (in-memory only — a retry needs the live flow).
	let iconArchive = TaskIconArchive()
	private var retryHandlers: [String: () -> Void] = [:]
	var downloadMirrors: [String: UnifiedTask] = [:]
	var cancellables = Set<AnyCancellable>()

    @Published private(set) var historyPersistenceIssue: TaskHistoryJournal.Issue?
    let historyJournal = TaskHistoryJournal(url: UnifiedTaskCenter.historyFileURL)
    var historyLoaded = false
    var historyLoading = false
    var clearHistoryRequested = false

	static let historyLimit = 200
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
		// A double tap must not become two tasks for one operation. A queued duplicate has
		// done no work, so the caller can adopt it; anything further along is already running
		// and is returned as-is rather than restarted.
		if phase == .queued,
		   let existing = TaskSubmissionPolicy.adoptable(kind: kind, subjectID: subjectID, in: tasks) {
			return existing
		}
		if let running = TaskSubmissionPolicy.inFlight(kind: kind, subjectID: subjectID, in: tasks),
		   running.phase != .queued {
			Logger.misc.notice("Task of kind \(kind.rawValue, privacy: .public) is already running for this subject; not starting a second one.")
			return running
		}
		let task = UnifiedTask(kind: kind, title: title, subtitle: subtitle, phase: phase, progress: progress, subjectID: subjectID)
		tasks.insert(task, at: 0)
        _persistHistory()
		return task
	}

	func transition(_ task: UnifiedTask, to phase: UnifiedTaskPhase, progress: Double? = nil, error: String? = nil) {
		let previousPhase = task.phase
        guard task.move(to: phase) else { return }
		// A stage change may start lower than the stage before it; within a stage, progress
		// never rewinds. A completed task is at 100% whatever the last callback said.
		let proposed = progress ?? task.progress
		task.progress = TaskProgressRule.final(
			phase: phase,
			current: TaskProgressRule.next(
				previous: task.progress,
				proposed: proposed,
				stageChanged: phase != previousPhase
			)
		)
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
		// Same stage, so the floor applies: a late callback from an abandoned step cannot drag
		// the bar backwards, and a caller cannot report past 100%.
		task.progress = TaskProgressRule.next(previous: task.progress, proposed: progress, stageChanged: false)
		task.updatedAt = Date()
		objectWillChange.send()
	}

	func cancel(_ task: UnifiedTask) {
		guard !task.phase.isTerminal else { return }
		transition(task, to: .cancelled)
	}

	func registerRetry(_ task: UnifiedTask, handler: @escaping () -> Void) {
		// Only a stopped task can be retried. Registering against a running one used to be
		// accepted by a guard that was always true, which kept a live closure alive for the
		// lifetime of the process.
		guard TaskRetryPolicy.canOffer(task.phase) else { return }
		retryHandlers[task.id] = handler
	}

    func canRetry(_ task: UnifiedTask) -> Bool {
        TaskRetryPolicy.canOffer(task.phase) && retryHandlers[task.id] != nil
    }

	/// Retry a failed/cancelled task when its flow registered a handler.
	/// Returns false when no live handler exists (e.g. after a relaunch).
	@discardableResult
	func retry(_ task: UnifiedTask) -> Bool {
		guard canRetry(task), let handler = retryHandlers[task.id] else { return false }
        retryHandlers.removeValue(forKey: task.id)
        // Resumed downloads receive a fresh mirror too, not a terminal record
        // whose progress would be silently ignored.
        let mirrorIDs = downloadMirrors.filter { $0.value.id == task.id }.map { $0.key }
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

	func _finalize(_ task: UnifiedTask) {
		// A finished task cannot be retried, and the closure it registered may hold the flow
		// that produced it. Releasing it here is what keeps a long session from accumulating
		// one live closure per finished task.
		retryHandlers.removeValue(forKey: task.id)
		if let index = tasks.firstIndex(where: { $0.id == task.id }) {
			tasks.remove(at: index)
		}
		history.insert(task, at: 0)
		if history.count > Self.historyLimit {
			history = Array(history.prefix(Self.historyLimit))
		}
		_persistHistory()
	}

	// MARK: - Persistence

	func _loadHistory() {
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
						let live: [UnifiedTask] = self.tasks + self.history
						let liveIDs: Set<String> = Set(live.map { $0.id })
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

	func _persistHistory() {
		guard historyLoaded else {
			// Retry unavailable reads on subsequent activity or device unlock.
			// Never replace a journal we have not successfully read/preserved.
			_loadHistory()
			return
		}
		pruneHistoryIcons()
		// Capture values on the main actor; no mutable UnifiedTask crosses to IO.
		let snapshots: [UnifiedTask.Snapshot] = (tasks + history).map { $0.snapshot }

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
}