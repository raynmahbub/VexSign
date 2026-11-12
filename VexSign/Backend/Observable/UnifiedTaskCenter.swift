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

    @Published var historyPersistenceIssue: TaskHistoryJournal.Issue?
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

	func _finalize(_ task: UnifiedTask) {
		if let index = tasks.firstIndex(where: { $0.id == task.id }) {
			tasks.remove(at: index)
		}
		history.insert(task, at: 0)
		if history.count > Self.historyLimit {
			history = Array(history.prefix(Self.historyLimit))
		}
		_persistHistory()
	}

	/// Clears the persisted history (Settings → Diagnostics).
	func clearHistory() {
        clearHistoryRequested = !historyLoaded
        history = []
        _persistHistory()
		objectWillChange.send()
	}
}