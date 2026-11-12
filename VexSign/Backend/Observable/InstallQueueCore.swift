//
//  InstallQueueCore.swift
//  VexSign
//
//  Core queue logic for the installation queue.
//

import Foundation
import SwiftUI
import NimbleExtensions
import IDeviceSwift

// MARK: - Core Queue

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

	/// Per-entry outcome, keyed by the entry's id, so the queue list view can show what happened.
	@Published private(set) var outcomes: [String: InstallOutcome] = [:]

	/// The unified-task record for the current queue run (nil when idle).
    private var preparedNext: (id: String, installer: AppInstaller)?
	private var unifiedTask: UnifiedTask?
    private var preserveDeliveryOnTeardown = false
    var currentTaskID: String? { unifiedTask?.id }
	/// The installation attempt registered with `LibraryStatusStore` for the installer in flight,
	/// so the library can publish `Installing` for exactly as long as the attempt is monitored.
	/// Carries its own attempt ID: a completion from an abandoned installer must not end it.
	private var activeInstallation: (identifier: String, attemptID: String)?
	/// Bumped whenever the queue starts over. Scheduled work captures the generation it was
	/// created under, so a completion from an abandoned run cannot advance, dismiss or rewrite a
	/// newer one.
	private(set) var runGeneration = 0
	/// Success stays on screen briefly for feedback, but a later Skip/Retry must cancel that
	/// pending transition so it cannot advance a different app after the queue has moved on.
	private let advanceScheduler = InstallQueueAdvanceScheduler()

	var current: AnyApp? { apps.indices.contains(index) ? apps[index] : nil }
	var upcoming: [AnyApp] { Array(apps.dropFirst(index + 1)) }
	var showsPill: Bool { current != nil && !isSheetPresented && !isFinished }

    /// Exports bypass app routing. An unresolved route stays invalid (-1), so the real installer
    /// reports its actionable error rather than queue bookkeeping accidentally treating it as OTA.
    private func _installationMethod(for entry: AnyApp) -> Int {
        guard !entry.archive else { return 0 }
        do { return try SigningModeManager.shared.pipeline(for: entry.base).installationMethodValue }
        catch { return -1 }
    }

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

	var hasFailure: Bool { failurePresentation != nil }

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
              let current, let next = upcoming.first else { return }
        let currentMethod = _installationMethod(for: current)
        let nextMethod = _installationMethod(for: next)
        guard currentMethod == 0,
              InstallPreparationPolicy.allows(
                installationMethod: nextMethod,
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
			let preparesGuest = !current.archive && _installationMethod(for: current) == 2
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
            trace.expectedBundleIdentifier = current.base.identifier
            trace.monitoringActive = true
            trace.artifactID = current.base.uuid
            if let directory = Storage.shared.getAppDirectory(for: current.base),
               let info = NSDictionary(contentsOf: directory.appendingPathComponent("Info.plist")) {
                trace.appBuild = TaskContext.versionToken(info["CFBundleVersion"] as? String)
            }
            let method = _installationMethod(for: current)
            trace.installationMethod = current.archive ? "export" : (method == 1 ? "paired-device" : (method == 2 ? "guest-import" : (method == 0 ? "OTA" : "unresolved")))
            trace.signingTaskID = UnifiedTaskCenter.shared.history.first {
                $0.kind == .sign && $0.context?.artifactID == current.base.uuid && current.base.uuid != nil
            }?.id
            task.context = trace
            installer.onWorkflowStage = { [weak self, weak installer] phase in
                guard let self, let installer, self.installer === installer else { return }
                task.context?.installationMethod = installer.installationMethodCode
                if installer.hasHandedOffInstall && task.context?.handoffAt == nil {
                    task.context?.handoffAt = Date()
                }
                UnifiedTaskCenter.shared.transition(task, to: phase)
                if let active = self.activeInstallation {
                    LibraryStatusStore.shared.updateInstallationPhase(
                        identifier: active.identifier, attemptID: active.attemptID, phase: task.phase)
                }
            }
            installer.onConfirmationReason = { reason in task.context?.confirmationReason = reason }
        }
        installer.onPackaged = { [weak self, weak installer] in
            guard let self, let installer, self.installer === installer else { return }
            self._prepareNext()
        }
		self.installer = installer
		// Register the attempt at the moment the installer really starts, never when an install
		// was merely requested: from here until a terminal outcome, the library says "Installing"
		// instead of publishing whatever a mid-install device probe happens to answer.
		_beginInstallationAttempt(for: current, taskID: unifiedTask?.id)
		let attemptID = activeInstallation?.attemptID
		installer.start { [weak self, weak installer] result in
            guard let self, let installer, self.installer === installer else { return }
            self._handle(result, attemptID: attemptID)
        }
	}

    /// Activation is a request to check, never a statement about the iOS dialog.
    func reconcileOnForeground() {
        guard let installer, let task = unifiedTask, !task.phase.isTerminal,
              installer.hasOpenedInstallHandoff else { return }
        task.context?.lastReconciliationAt = Date()
        UnifiedTaskCenter.shared.transition(task, to: task.phase)
        installer.reconcileOnForeground()
    }

	// MARK: Installation lifecycle

	/// Registers this entry's installation with the library status store.
	///
	/// Only an operation that can actually install is registered. An export never touches iOS's
	/// installed-app registry, and a guest import stages an IPA in the container inbox — claiming
	/// "Installing" for either would be the same kind of unsupported claim this prevents.
	private func _beginInstallationAttempt(for entry: AnyApp, taskID: String?) {
		_endInstallationAttempt()
		guard !entry.archive,
              (0...1).contains(_installationMethod(for: entry)),
			  let identifier = entry.base.identifier, !identifier.isEmpty else { return }
		let attemptID = Self.attemptID(runGeneration: runGeneration, taskID: taskID, entryID: entry.id)
		activeInstallation = (identifier, attemptID)
		LibraryStatusStore.shared.beginInstallation(
			identifier: identifier, attemptID: attemptID, taskID: taskID
		)
	}

	/// Ends the registered attempt. `attemptID` is the one captured when the installer started:
	/// a stale completion carries its own and is ignored rather than ending a newer attempt.
	private func _endInstallationAttempt(expecting attemptID: String? = nil) {
		guard let active = activeInstallation,
			  Self.mayEndAttempt(registered: active.attemptID, reportedByCompletion: attemptID) else { return }
		activeInstallation = nil
		LibraryStatusStore.shared.endInstallation(
			identifier: active.identifier, attemptID: active.attemptID
		)
	}

	// MARK: Race rules

	/// The attempt ID registered with the library for one start.
	///
	/// Unique per start, and carrying the run generation plus the task record so a completion from
	/// an abandoned run can never be mistaken for the current one's.
	static func attemptID(runGeneration: Int, taskID: String?, entryID: String) -> String {
		"install-\(runGeneration)-\(taskID ?? "untracked")-\(entryID)"
	}

	/// Whether a completion may end the attempt now registered.
	///
	/// `nil` means the queue itself is retiring its installer — Skip, Retry, Stop, advance or
	/// reset — where there is no completion to compare against and the registered attempt is by
	/// definition the one being retired.
	static func mayEndAttempt(registered: String?, reportedByCompletion: String?) -> Bool {
		guard let registered, !registered.isEmpty else { return false }
		guard let reportedByCompletion else { return true }
		return reportedByCompletion == registered
	}

	/// Whether work a finished attempt scheduled may still act on the queue.
	///
	/// Both guards matter: the entry check rejects a queue that moved on to another app, and the
	/// generation check rejects a run that was reset and restarted underneath the scheduled work.
	static func mayRunScheduledWork(
		scheduledGeneration: Int,
		currentGeneration: Int,
		scheduledEntryID: String,
		currentEntryID: String?
	) -> Bool {
		scheduledGeneration == currentGeneration && currentEntryID == scheduledEntryID
	}

	/// Whether a finished run's deferred teardown may still clear the queue.
	///
	/// A queue started inside the dismissal window has a newer generation and is not finished, so
	/// an old completion cannot tear down the installation that replaced it.
	static func mayDismissFinishedRun(
		scheduledGeneration: Int,
		currentGeneration: Int,
		isFinished: Bool,
		isSheetPresented: Bool
	) -> Bool {
		scheduledGeneration == currentGeneration && isFinished && !isSheetPresented
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
        preserveDeliveryOnTeardown = installer?.hasHandedOffInstall == true
        if let task = unifiedTask {
            task.context?.confirmationReason = preserveDeliveryOnTeardown
                ? "monitoring-stopped-install-may-continue" : "preparation-cancelled"
            _recordVerificationAttempts(on: task)
            task.context?.monitoringActive = false
            UnifiedTaskCenter.shared.transition(task, to: Self.phaseAfterStoppingMonitoring(hasHandedOff: preserveDeliveryOnTeardown))
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

    /// Cancelling preparation is different from stopping observation of a handed-off install.
    static func phaseAfterStoppingMonitoring(hasHandedOff: Bool) -> UnifiedTaskPhase {
        hasHandedOff ? .unconfirmed : .cancelled
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
        retiringInstaller?.stop(preserveHandoff: preserveDeliveryOnTeardown)
        preserveDeliveryOnTeardown = false
		// `stop()` reports no outcome, so every path that retires an installer — Skip, Retry,
		// Stop, advance, reset — has to end the monitored attempt itself. Without this a skipped
		// install left its library row saying "Installing" until the backstop expired.
		_endInstallationAttempt()
	}

    var latestReportTask: UnifiedTask?

	private func _handle(_ result: Result<AppInstaller.Outcome, Error>, attemptID: String? = nil) {
		// An installer completion is always terminal, so the monitored attempt ends here — before
		// any branch presents, advances or resets. A confirmed install was already recorded by the
		// installer, and ending the attempt is what lets that evidence become the published state.
		_endInstallationAttempt(expecting: attemptID)
        if let task = unifiedTask {
            latestReportTask = task
            task.context?.installationMethod = installer?.installationMethodCode
            task.context?.monitoringActive = false
            task.context?.lastReconciliationAt = Date()
            _recordVerificationAttempts(on: task)
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
			// Close this attempt's record here, as cancelled. Left open, it was closed as
			// Completed when this was the last app - and when it was not, the next app ran on
			// it: a record still titled with the declined app went through the next app's
			// stages, "Verifying installation" included, and the app really being installed
			// had no record of its own.
			_finishUnifiedTask(cancelled: true)
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
            let localTrustFailure: Error?
            if let localError = error as? ServerInstaller.LocalInstallError,
               case .unavailable(let underlying) = localError {
                localTrustFailure = underlying
            } else {
                localTrustFailure = nil
            }
            // Three different situations that used to share one message and one title. iOS
            // filtering its own install status is not a failed install; an install that never
            // started put nothing on the device either, and must not imply it might have.
            let kind = FailureKind.resolve(error: error, needsTrust: localTrustFailure != nil)
			if kind.recordsFailure {
				unifiedTask?.context?.recordFailure(error)
			}
			_discardPreparation()
			NBHaptic.notify(kind == .unconfirmed ? .warning : .error)
			if let current {
                outcomes[current.id] = kind == .unconfirmed ? .unconfirmed : .failed(String(describing: error))
			}
			if let task = unifiedTask {
				UnifiedTaskCenter.shared.transition(task, to: kind.taskPhase,
													error: kind.taskPhase == .unconfirmed ? nil : error.localizedDescription)
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
            failurePresentation = FailurePresentation(
                title: kind.title,
                message: kind.summary,
                details: LogRedaction.redact(localTrustFailure?.localizedDescription ?? error.localizedDescription),
                needsTrust: kind == .needsTrust,
                canRetryLocally: installer?.canRetryUsingLocalhost == true,
                waitingCount: upcoming.count
            )
            if kind.releasesSheet {
                // Keep the report and recovery actions in Activity/the queue pill,
                // but do not hold the whole app behind an unobservable spinner.
                isSheetPresented = false
                Toast.info(.localized("iOS did not expose installation status. Check the Home Screen; the report is available in Activity. No reinstall was started."))
            }
		}
	}

    private func _scheduleAdvance(after delay: TimeInterval, for entryID: String?) {
        guard let entryID else { return }
        let generation = runGeneration
        advanceScheduler.schedule(after: delay) { [weak self] in
            // Both guards matter: the entry check rejects a queue that moved on, and the
            // generation check rejects a completion from a run that was reset and restarted.
            guard let self, Self.mayRunScheduledWork(
                scheduledGeneration: generation,
                currentGeneration: self.runGeneration,
                scheduledEntryID: entryID,
                currentEntryID: self.current?.id
            ) else { return }
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
        let generation = runGeneration
        advanceScheduler.schedule(after: 0.6) { [weak self] in
            // A queue started inside this window has a newer generation, so a finished run's
            // timer cannot tear down the installation that replaced it.
            guard let self, Self.mayDismissFinishedRun(
                scheduledGeneration: generation,
                currentGeneration: self.runGeneration,
                isFinished: self.isFinished,
                isSheetPresented: self.isSheetPresented
            ) else { return }
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

	/// Keeps the number of device checks the installer made on the task record, so the report of
	/// an install that waited on verification says how many times the device was asked.
	private func _recordVerificationAttempts(on task: UnifiedTask) {
		guard let checks = installer?.verificationAttempt, checks > 0 else { return }
		task.context?.verificationAttempts = checks
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
		// Bump first: everything scheduled by the run being abandoned captured the old
		// generation and is now inert, including a pending success advance or dismissal.
		runGeneration += 1
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
		// A reset ends every monitored attempt, so no library row can be left claiming
		// "Installing" for a queue that no longer exists.
		LibraryStatusStore.shared.resetInstallations()

		InstallCleanup.flush()
	}
}