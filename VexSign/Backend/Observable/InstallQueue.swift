//
//  InstallQueue.swift
//  VexSign
//
//  Created by VexSign Team on 24.08.2026.
//

import Foundation
import SwiftUI
import NimbleExtensions
import IDeviceSwift

/// Every install and export runs through here. One sheet at a time keeps the OTA server from
/// starting twice and lets a job survive a dismissed sheet. On failure the queue no longer
/// abandons the whole run: it marks the app failed, keeps the rest, and offers retry / skip.
@MainActor
final class InstallQueue: ObservableObject {
	static let shared = InstallQueue()

	@Published private(set) var apps: [AnyApp] = []
	@Published private(set) var index = 0
	@Published private(set) var installer: AppInstaller?
	@Published private(set) var isFinished = false
	@Published private(set) var isPaused = false
	@Published var isSheetPresented = false

	/// Per-entry outcome, keyed by the entry's id, so the queue list view can show what happened.
	@Published private(set) var outcomes: [String: InstallOutcome] = [:]

	/// The unified-task record for the current queue run (nil when idle).
	private var unifiedTask: UnifiedTask?
	/// Success stays on screen briefly for feedback, but a later Skip/Retry must cancel that
	/// pending transition so it cannot advance a different app after the queue has moved on.
	private let advanceScheduler = InstallQueueAdvanceScheduler()

	enum InstallOutcome: Equatable {
		case pending
		case succeeded
		case guestPrepared
		case failed(String)
		case skipped

		func canOpenApp(isExport: Bool, identifier: String?) -> Bool {
			self == .succeeded && !isExport && !(identifier ?? "").isEmpty
		}
	}

	private init() {}

	var current: AnyApp? { apps.indices.contains(index) ? apps[index] : nil }
	var upcoming: [AnyApp] { Array(apps.dropFirst(index + 1)) }
	var showsPill: Bool { current != nil && !isSheetPresented && !isFinished }

	/// Exports share the success counter, but must never get an Open action.
	var installedApps: [AnyApp] {
		apps.filter {
			outcomes[$0.id]?.canOpenApp(isExport: $0.archive, identifier: $0.base.identifier) == true
		}
	}

	var succeededCount: Int { outcomes.values.filter { $0 == .succeeded }.count }
	var failedCount: Int {
		outcomes.values.filter {
			if case .failed = $0 { return true }
			return false
		}.count
	}

	/// A finished run has nothing left to reopen, so closing it retires the queue.
	func sheetDismissed() {
		if isFinished { clear() }
	}

	func enqueue(_ app: AppInfoPresentable, exporting: Bool = false) {
		let entry = AnyApp(base: app, archive: exporting)
		guard !apps.contains(where: { $0.id == entry.id }) else { return }

		if isFinished { _reset() }
		apps.append(entry)
		outcomes[entry.id] = .pending

		InstallQueueWindow.shared.ensure()
		isSheetPresented = true
		activate()
	}

	/// Never starts in the background since an OTA install needs its prompt on screen.
	func activate(useLocalhost: Bool = false) {
		guard
			!isPaused,
			installer == nil,
			let current,
			UIApplication.shared.applicationState != .background
		else {
			return
		}

		// Unified task pipeline: one record per queue run.
		if unifiedTask == nil {
			let title = apps.count > 1
				? String.localized("%lld apps", arguments: apps.count)
				: (current.base.name ?? .localized("App"))
			let preparesGuest = !current.archive && UserDefaults.standard.integer(forKey: "VexSign.installationMethod") == 2
			unifiedTask = UnifiedTaskCenter.shared.begin(
				kind: current.archive || preparesGuest ? .export : .install,
				title: title,
				subtitle: preparesGuest ? .localized("Preparing guest import") : (current.archive ? .localized("Exporting") : .localized("Installing")),
				phase: preparesGuest ? .extracting : .installing
			)
		}

		let installer = AppInstaller(app: current.base, isSharing: current.archive, useLocalhost: useLocalhost)
		self.installer = installer
		installer.start { [weak self] result in self?._handle(result) }
	}

	/// Pauses between apps: the current install finishes, the next holds.
	func pause() {
		isPaused = true
	}

	func resume() {
		guard isPaused else { return }
		isPaused = false
		if installer == nil { activate() }
	}

	func clear() {
		_reset()
		isSheetPresented = false
		InstallQueueWindow.shared.teardown()
	}

	/// Skips the current app permanently (marks it skipped and moves on).
	func skip() {
        NBHaptic.tap()
        advanceScheduler.cancel()
		guard let current else { _abandon(); return }
		outcomes[current.id] = .skipped
		_abandon()
	}

	/// Retries the app at `index` (or the current one) by reinstating it and advancing back.
	func retryCurrent(useLocalhost: Bool = false) {
        NBHaptic.tap()
        advanceScheduler.cancel()
		guard apps.indices.contains(index) else { return }
		_teardownInstaller()
		outcomes[apps[index].id] = .pending
		isPaused = false
		activate(useLocalhost: useLocalhost)
	}

	/// Marks the failed app as pending again and rebuilds a fresh installer for it.
	private func _teardownInstaller() {
		installer?.stop()
		installer = nil
	}

	private func _handle(_ result: Result<AppInstaller.Outcome, Error>) {
		switch result {
		case .success(.cancelled):
			if let current { outcomes[current.id] = .skipped }
			_syncUnifiedTaskProgress()
			_abandon()
		case .success(.guestImportPrepared):
			if let current { outcomes[current.id] = .guestPrepared }
			unifiedTask?.subtitle = .localized("Guest import prepared — finish in container")
			// The host accepts one pending import. Never run a batch through a restart
			// or delete its library copy as if iOS had installed it.
			for entry in apps.dropFirst(index + 1) { outcomes[entry.id] = .skipped }
			_syncUnifiedTaskProgress()
			_teardownInstaller()
			isFinished = true
			_finishUnifiedTask()
			isSheetPresented = false
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
				UIAlertController.showAlertWithOptions(
					title: .localized("Guest import prepared"),
					message: .localized("The IPA is in the host inbox, not installed on iOS. Open the container to finish import and signing. Switching closes this VexSign session. Remaining queued apps were skipped; import guests one at a time."),
					actions: [
						(.localized("Open container"), .default, {
							guard !UnifiedTaskCenter.shared.tasks.contains(where: { $0.phase.isInProgress }) else {
								Toast.info(.localized("Finish active tasks first. The guest IPA remains staged in the container inbox."))
								return
							}
							if !EmbeddedContainerRuntime.open(.container) {
								Toast.info(.localized("The host could not switch sessions. The guest IPA remains staged; open the container home to finish import."))
							}
						}),
						(.localized("Later"), .cancel, nil)
					])
			}

		case .success(.exported(let package)):
			if let current { outcomes[current.id] = .succeeded }
			_syncUnifiedTaskProgress()
			_abandon()

			guard let package else { return }
			// Let the card leave first or the share sheet presents onto a dying view.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
				UIActivityViewController.show(activityItems: [package])
			}
		case .success(.installedOtherVersion(let version)):
            NBHaptic.notify(.success)
			// The device proved an install, but not the version that was sent. That is a success
			// with a footnote, so say the footnote.
			if let current { outcomes[current.id] = .succeeded }
			if let app = installer?.app { InstallCleanup.stage(app) }
			Toast.info(.localized(
				"Installed, but the device reports version %@.",
				arguments: version ?? .localized("unknown")
			))
			_syncUnifiedTaskProgress()
			_scheduleAdvance(after: 1.2, for: current?.id)
		case .success:
            NBHaptic.notify(.success)
			if let current { outcomes[current.id] = .succeeded }
			if let app = installer?.app { InstallCleanup.stage(app) }
			_syncUnifiedTaskProgress()
			// Let the finished ring land before the next app takes over. The scheduled advance is
			// invalidated if the user skips/retries or the queue is otherwise reset first.
			_scheduleAdvance(after: 1.2, for: current?.id)
		case .failure(let error):
            NBHaptic.notify(.error)
			if let current {
				outcomes[current.id] = .failed(String(describing: error))
			}
			if let task = unifiedTask {
				UnifiedTaskCenter.shared.transition(task, to: .failed, error: error.localizedDescription)
				// The queue may continue with other apps — reopen the record.
				UnifiedTaskCenter.shared.registerRetry(task) { [weak self] in
					self?.retryCurrent()
				}
				unifiedTask = nil
			}
            let failedEntryID = current?.id
			var actions: [(String, UIAlertAction.Style, (() -> Void)?)] = [
				(.localized("Retry"), .default, { [weak self] in
					HeartbeatManager.shared.start(true)
                    self?._afterInstallAlertDismisses(for: failedEntryID) { $0.retryCurrent() }
				})
			]
			if installer?.canRetryUsingLocalhost == true {
				actions.append((.localized("Retry with Semi Local (localhost)"), .default, { [weak self] in
                    self?._afterInstallAlertDismisses(for: failedEntryID) { $0.retryCurrent(useLocalhost: true) }
				}))
			}
			actions.append((upcoming.isEmpty ? .localized("Close") : .localized("Skip"), .default, { [weak self] in
				HeartbeatManager.shared.start(true)
                self?._afterInstallAlertDismisses(for: failedEntryID) { $0.skip() }
			}))
			actions.append((.localized("Stop"), .cancel, { [weak self] in
				HeartbeatManager.shared.start(true)
                self?._afterInstallAlertDismisses(for: failedEntryID) { $0._abandonAndFinish() }
			}))
            actions.insert((.localized("View installation details"), .default, {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    UIAlertController.showAlertWithOk(title: .localized("Installation Details"), message: error.localizedDescription)
                }
            }), at: 0)
            let needsTrust: Bool
            if let localError = error as? ServerInstaller.LocalInstallError, case .unavailable = localError { needsTrust = true }
            else { needsTrust = false }
            let summary = needsTrust
                ? String.localized("Local HTTPS verification failed. Check the identity in Settings → Installation → Server & SSL, export and install its Root CA profile, then enable Full Trust in iOS Certificate Trust Settings.")
                : String.localized("VexSign could not confirm installation. If the app is already on your Home Screen, close this dialog and open it there. Otherwise review installation details before retrying.")
            let waiting = upcoming.isEmpty ? "" : "\n\n" + String.localized("%lld more apps are waiting.", arguments: upcoming.count)
            UIAlertController.showAlertWithOptions(
                title: needsTrust ? .localized("HTTPS Setup Required") : (error is InstallConfirmation.Failure ? .localized("Installation Not Confirmed") : .localized("Install Failed")),
                message: summary + waiting,
                actions: actions
            )
		}
	}

    /// UIAlertAction handlers run before UIKit has finished dismissing the alert. Keep queue
    /// transitions off that dismissal transaction so Skip/Retry cannot tear down the window
    /// that is still animating the alert.
    private func _afterInstallAlertDismisses(
        for entryID: String?,
        _ action: @escaping (InstallQueue) -> Void
    ) {
        guard let entryID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.current?.id == entryID else { return }
            action(self)
        }
    }

    private func _scheduleAdvance(after delay: TimeInterval, for entryID: String?) {
        guard let entryID else { return }
        advanceScheduler.schedule(after: delay) { [weak self] in
            guard let self, self.current?.id == entryID else { return }
            self._advance()
        }
    }

	/// Keeps the unified task's progress in step with the queue (index of the
	/// app being installed out of the total).
	private func _syncUnifiedTaskProgress() {
		guard let task = unifiedTask, !apps.isEmpty else { return }
		UnifiedTaskCenter.shared.update(task, progress: Double(index + 1) / Double(apps.count))
	}

    /// Retire a completed queue so its install card does not cover the app screen.
	private func _advance() {
        advanceScheduler.cancel()
        guard current != nil else { return }
		_teardownInstaller()

		guard index + 1 < apps.count else {
			isFinished = true
            _finishUnifiedTask()
            let wasPresented = isSheetPresented
            isSheetPresented = false
            // The sheet's onDismiss clears state after its dismissal animation.
            if !wasPresented { clear() }
            return
		}

		index += 1
		activate()
	}

	/// Dismiss first so the card doesn't blank out mid animation.
	private func _abandon() {
        advanceScheduler.cancel()
		guard index + 1 < apps.count else {
			guard isSheetPresented else {
				_finishUnifiedTask()
				clear()
				return
			}

			_teardownInstaller()
			isFinished = true
			_finishUnifiedTask()
			isSheetPresented = false
			return
		}

		_advance()
	}

	/// Finishes with the remainder marked skipped, used by "Stop".
	private func _abandonAndFinish() {
        advanceScheduler.cancel()
		for entry in apps.dropFirst(index + 1) where outcomes[entry.id] == nil || outcomes[entry.id] == .pending {
			outcomes[entry.id] = .skipped
		}
		_teardownInstaller()
		isFinished = true
		_finishUnifiedTask(cancelled: true)
		isSheetPresented = false
	}

	/// Closes the unified task record for this queue run.
	private func _finishUnifiedTask(cancelled: Bool = false) {
		guard let task = unifiedTask else { return }
		unifiedTask = nil
		if cancelled {
			UnifiedTaskCenter.shared.transition(task, to: .cancelled)
		} else {
			let failedCount = outcomes.values.filter {
				if case .failed = $0 { return true }
				return false
			}.count
			UnifiedTaskCenter.shared.transition(
				task,
				to: failedCount > 0 ? .failed : .completed,
				progress: 1,
				error: failedCount > 0
					? String.localized("%lld install(s) failed", arguments: failedCount)
					: nil
			)
		}
	}

	private func _reset() {
        advanceScheduler.cancel()
		_teardownInstaller()
		apps.removeAll()
		index = 0
		isFinished = false
		isPaused = false
		outcomes.removeAll()
		unifiedTask = nil

		InstallCleanup.flush()
	}
}

/// A cancellable, main-actor timer for the small success animation window. Cancelling the task
/// prevents an old completion from advancing a newer queue item after Skip, Retry, or Clear.
@MainActor
final class InstallQueueAdvanceScheduler {
    private var pendingTask: Task<Void, Never>?

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        cancel()
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingTask = nil
            action()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}
