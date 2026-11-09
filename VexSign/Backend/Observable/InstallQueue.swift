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
    @Published private(set) var failurePresentation: FailurePresentation?

    struct FailurePresentation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let details: String
        let needsTrust: Bool
        let canRetryLocally: Bool
        let waitingCount: Int
    }

    var hasFailure: Bool { failurePresentation != nil }

	/// Per-entry outcome, keyed by the entry's id, so the queue list view can show what happened.
	@Published private(set) var outcomes: [String: InstallOutcome] = [:]

	/// The unified-task record for the current queue run (nil when idle).
    private var preparedNext: (id: String, installer: AppInstaller)?
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
        if installer?.hasPackaged == true { _prepareNext() }
	}

    /// One lookahead only. Preparation overlaps the current OTA transfer/verification,
    /// not another archive build, prompt or server. Pause keeps a ready package parked.
    private func _prepareNext() {
        guard !isFinished, !hasFailure, installer?.hasPackaged == true,
              let current, let next = upcoming.first,
              InstallPreparationPolicy.allows(
                installationMethod: UserDefaults.standard.integer(forKey: "VexSign.installationMethod"),
                currentIsExport: current.archive, nextIsExport: next.archive) else { return }
        guard preparedNext?.id != next.id else { return }
        _discardPreparation()
        let nextInstaller = AppInstaller(app: next.base)
        preparedNext = (next.id, nextInstaller)
        nextInstaller.prepareForQueuedOTA()
    }

    private func _discardPreparation() {
        preparedNext?.installer.stop()
        preparedNext = nil
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

		// One independent task record per item/attempt, not one mutable batch verdict.
		if unifiedTask == nil {
			let title = current.base.name ?? .localized("App")
			let preparesGuest = !current.archive && UserDefaults.standard.integer(forKey: "VexSign.installationMethod") == 2
			unifiedTask = UnifiedTaskCenter.shared.begin(
				kind: current.archive || preparesGuest ? .export : .install,
				title: title,
				subtitle: preparesGuest ? .localized("Preparing guest import") : (current.archive ? .localized("Exporting") : .localized("Installing")),
				phase: current.archive || preparesGuest ? .extracting : .preparingInstallation,
                progress: -1,
                subjectID: current.base.uuid
			)
		}

        let installer: AppInstaller
        if let prepared = preparedNext, prepared.id == current.id,
           !useLocalhost, prepared.installer.preparationMatchesSettings {
            installer = prepared.installer
            preparedNext = nil
        } else {
            _discardPreparation()
            installer = AppInstaller(app: current.base, isSharing: current.archive, useLocalhost: useLocalhost)
        }
        if let task = unifiedTask {
            var trace = TaskContext()
            trace.appVersion = TaskContext.versionToken(current.base.version)
            trace.artifactID = current.base.uuid
            if let directory = Storage.shared.getAppDirectory(for: current.base),
               let info = NSDictionary(contentsOf: directory.appendingPathComponent("Info.plist")) {
                trace.appBuild = TaskContext.versionToken(info["CFBundleVersion"] as? String)
            }
            let method = UserDefaults.standard.integer(forKey: "VexSign.installationMethod")
            trace.installationMethod = current.archive ? "export" : (method == 1 ? "paired-device" : (method == 2 ? "guest-import" : "OTA"))
            trace.signingTaskID = UnifiedTaskCenter.shared.history.first {
                $0.kind == .sign && $0.context?.artifactID == current.base.uuid && current.base.uuid != nil
            }?.id
            task.context = trace
            installer.onWorkflowStage = { [weak self, weak installer] phase in
                guard let self, let installer, self.installer === installer else { return }
                task.context?.installationMethod = installer.installationMethodCode
                UnifiedTaskCenter.shared.transition(task, to: phase)
            }
            installer.onConfirmationReason = { reason in task.context?.confirmationReason = reason }
        }
        installer.onPackaged = { [weak self, weak installer] in
            guard let self, let installer, self.installer === installer else { return }
            self._prepareNext()
        }
		self.installer = installer
		installer.start { [weak self, weak installer] result in
            guard let self, let installer, self.installer === installer else { return }
            self._handle(result)
        }
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
	func skip(forEntryID entryID: String? = nil) {
		guard !isFinished, let current, entryID == nil || current.id == entryID else { return }
		// A completion can arrive just before SwiftUI removes the Skip control. Ignore
		// that stale tap so it cannot cancel the successful item's automatic dismissal.
		guard Self.canSkip(outcome: outcomes[current.id], hasFailure: failurePresentation != nil) else { return }

		NBHaptic.tap()
		advanceScheduler.cancel()
		failurePresentation = nil
		outcomes[current.id] = .skipped
        if let task = unifiedTask {
            task.context?.confirmationReason = "monitoring-stopped-install-may-continue"
            UnifiedTaskCenter.shared.transition(task, to: .cancelled)
            latestReportTask = task
            unifiedTask = nil
        }
        if !current.archive {
            Toast.info(.localized("Stopped monitoring this app. An installation already accepted by iOS may continue."))
        }
		// Skipping a held next item is an explicit request to move on; don't strand
		// the queue with no installer and no Resume control.
		isPaused = false
		_abandon()
	}

	static func canSkip(outcome: InstallOutcome?, hasFailure: Bool) -> Bool {
		hasFailure || outcome == .pending
	}

    func stopAfterFailure() {
        NBHaptic.tap()
        _abandonAndFinish()
    }

	/// Retries the app at `index` (or the current one) by reinstating it and advancing back.
	func retryCurrent(useLocalhost: Bool = false) {
        NBHaptic.tap()
        advanceScheduler.cancel()
        failurePresentation = nil
		guard apps.indices.contains(index) else { return }
		_teardownInstaller()
		outcomes[apps[index].id] = .pending
		isPaused = false
		activate(useLocalhost: useLocalhost)
	}

	/// Marks the failed app as pending again and rebuilds a fresh installer for it.
	private func _teardownInstaller() {
		let retiringInstaller = installer
		installer = nil
		retiringInstaller?.stop()
	}

    var latestReportTask: UnifiedTask?

	private func _handle(_ result: Result<AppInstaller.Outcome, Error>) {
        if let task = unifiedTask {
            latestReportTask = task
            task.context?.installationMethod = installer?.installationMethodCode
            if task.context?.confirmationReason == nil {
                switch result {
                case .success(.installed): task.context?.confirmationReason = "native-installation-completed"
                case .success(.installedOtherVersion): task.context?.confirmationReason = "device-reports-other-version"
                case .success(.guestImportPrepared): task.context?.confirmationReason = "guest-prepared-not-installed"
                case .success(.exported): task.context?.confirmationReason = "exported-not-installed"
                case .success(.cancelled): task.context?.confirmationReason = "cancelled"
                case .failure: task.context?.confirmationReason = "operation-failed"
                }
            }
        }
		switch result {
		case .success(.cancelled):
			if let current { outcomes[current.id] = .skipped }
			_syncUnifiedTaskProgress()
			_abandon()
		case .success(.guestImportPrepared):
            _discardPreparation()
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
            _finishUnifiedTask()
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
            _finishUnifiedTask()
			_scheduleAdvance(after: 0.25, for: current?.id)
		case .success:
            NBHaptic.notify(.success)
            Toast.success(.localized("Installation completed"), systemImage: "checkmark.circle.fill")
			if let current { outcomes[current.id] = .succeeded }
			if let app = installer?.app { InstallCleanup.stage(app) }
			_syncUnifiedTaskProgress()
            _finishUnifiedTask()
			// Let the finished ring land before the next app takes over. The scheduled advance is
			// invalidated if the user skips/retries or the queue is otherwise reset first.
			_scheduleAdvance(after: 0.25, for: current?.id)
		case .failure(let error):
			// iOS filtering its own install status is not a failed install. Keep the
			// report and the recovery actions, but do not record a failure the device
			// never reported.
			let unconfirmed = (error as? InstallConfirmation.Failure)?.verdict == .timedOutVerifying
			if !unconfirmed {
				unifiedTask?.context?.recordFailure(error)
			}
			_discardPreparation()
			NBHaptic.notify(unconfirmed ? .warning : .error)
			if let current {
				outcomes[current.id] = .failed(String(describing: error))
			}
			if let task = unifiedTask {
				UnifiedTaskCenter.shared.transition(task, to: unconfirmed ? .unconfirmed : .failed,
													error: unconfirmed ? nil : error.localizedDescription)
				// Keep this failed attempt; a retry starts a separate record.
                let failedEntryID = current?.id
                UnifiedTaskCenter.shared.registerRetry(task) { [weak self] in
                    guard let self, self.current?.id == failedEntryID, self.failurePresentation != nil else {
                        Toast.info(.localized("Restart installation from Signed Apps. The original task report is retained."))
                        return
                    }
                    self.retryCurrent()
                }
				unifiedTask = nil
			}
            let localTrustFailure: Error?
            if let localError = error as? ServerInstaller.LocalInstallError,
               case .unavailable(let underlying) = localError {
                localTrustFailure = underlying
            } else {
                localTrustFailure = nil
            }
            let needsTrust = localTrustFailure != nil
            let summary = needsTrust
                ? String.localized("Local HTTPS verification failed. Check the identity in Settings → Installation → Server & SSL, export and install its Root CA profile, then enable Full Trust in iOS Certificate Trust Settings.")
                : String.localized("VexSign could not confirm installation. If the app is already on your Home Screen, it may already be installed. Review the details below before retrying.")
            failurePresentation = FailurePresentation(
                title: needsTrust ? .localized("HTTPS Setup Required") : (error is InstallConfirmation.Failure ? .localized("Installation Not Confirmed") : .localized("Install Failed")),
                message: summary,
                details: LogRedaction.redact(localTrustFailure?.localizedDescription ?? error.localizedDescription),
                needsTrust: needsTrust,
                canRetryLocally: installer?.canRetryUsingLocalhost == true,
                waitingCount: upcoming.count
            )
            if let confirmation = error as? InstallConfirmation.Failure, confirmation.verdict == .timedOutVerifying {
                // Keep the report and recovery actions in Activity/the queue pill,
                // but do not hold the whole app behind an unobservable spinner.
                isSheetPresented = false
                Toast.info(.localized("iOS did not expose installation status. Check the Home Screen; the report is available in Activity. No reinstall was started."))
            }
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
	/// current attempt only; the queue retains its own aggregate counters).
	private func _syncUnifiedTaskProgress() {
		guard let task = unifiedTask, !apps.isEmpty else { return }
		UnifiedTaskCenter.shared.update(task, progress: 1)
	}

    /// Retire a completed queue so its install card does not cover the app screen.
	private func _advance() {
        advanceScheduler.cancel()
        failurePresentation = nil
        guard current != nil else { return }
		_teardownInstaller()

		guard index + 1 < apps.count else {
			isFinished = true
            _finishUnifiedTask()
            _dismissFinishedQueue()
            return
		}

		index += 1
		activate()
	}

    /// onDismiss is normally responsible for clearing the queue, but UIKit/SwiftUI
    /// can lose that callback when an OTA prompt backgrounds the overlay window.
    /// Retire it after the animation even in that case. Reset/enqueue cancels this
    /// timer, so an earlier completion cannot close a newer installation.
    private func _dismissFinishedQueue() {
        let wasPresented = isSheetPresented
        isSheetPresented = false
        guard wasPresented else { clear(); return }
        advanceScheduler.schedule(after: 0.6) { [weak self] in
            guard let self, self.isFinished, !self.isSheetPresented else { return }
            self.clear()
        }
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
            _dismissFinishedQueue()
			return
		}

		_advance()
	}

	/// Finishes with the remainder marked skipped, used by "Stop".
	private func _abandonAndFinish() {
        _discardPreparation()
        advanceScheduler.cancel()
        failurePresentation = nil
		for entry in apps.dropFirst(index + 1) where outcomes[entry.id] == nil || outcomes[entry.id] == .pending {
			outcomes[entry.id] = .skipped
		}
		_teardownInstaller()
		isFinished = true
		_finishUnifiedTask(cancelled: true)
		isSheetPresented = false
	}

	/// Closes the current attempt without rewriting earlier queue outcomes.
	private func _finishUnifiedTask(cancelled: Bool = false) {
		guard let task = unifiedTask else { return }
		unifiedTask = nil
		if cancelled {
			UnifiedTaskCenter.shared.transition(task, to: .cancelled)
		} else {
            UnifiedTaskCenter.shared.transition(task, to: .completed, progress: 1)
		}
	}

	private func _reset() {
        _discardPreparation()
        advanceScheduler.cancel()
        failurePresentation = nil
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
