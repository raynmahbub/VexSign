//
//  AppDelegate+BackgroundTasks.swift
//  VexSign
//
//  Background-task registration and handlers, split out of VexSignApp.swift so
//  the launch path and the BGTaskScheduler plumbing can be read independently.
//  Behaviour is unchanged; these are extension methods on the same AppDelegate.
//

import Foundation
import BackgroundTasks
import OSLog
import UIKit

extension AppDelegate {
	func _registerBackgroundTasks() {
        guard EmbeddedContainerRuntime.supportsScheduledGuestTasks else { return }
        if #available(iOS 19.0, *) {
            // BGContinuedProcessingTask: user-initiated download that starts foreground, continues backgrounded.
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "com.vexsign.background.download.continued",
                using: nil
            ) { task in
                guard let continuedTask = task as? BGContinuedProcessingTask else { return }
                self._handleContinuedProcessing(task: continuedTask)
            }
        }

        // BGProcessingTask: scheduled background downloads (iOS 16+).
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.vexsign.background.download",
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self._handleBackgroundDownload(task: processingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.vexsign.background.refresh",
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self._handleBackgroundRefresh(task: refreshTask)
        }

        // Scheduled automation: sources → updates → (optional) sign+queue → cleanup → notify.
        // Only scheduled when the user opts in (Settings → Automation).
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.vexsign.background.maintenance",
            using: nil
        ) { task in
            guard let maintenanceTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self._handleMaintenance(task: maintenanceTask)
        }
    }

    private func _handleMaintenance(task: BGProcessingTask) {
        let worker = Task { @MainActor in
            let result = await BackgroundAutomation.run(fromBackground: true)
            task.setTaskCompleted(success: result != nil)
            self.scheduleAutomationMaintenance()
        }

        // Expiration requests cooperative cancellation. The worker owns the one
        // completion call after the runner unwinds; completing here as well
        // races the worker and lets its signing/download work continue untracked.
        task.expirationHandler = {
            worker.cancel()
        }
    }

    /// Schedules the next automated maintenance pass. Call after a run and on launch when enabled.
    func scheduleAutomationMaintenance() {
        guard EmbeddedContainerRuntime.supportsScheduledGuestTasks else { return }
        let identifier = "com.vexsign.background.maintenance"
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard BackgroundAutomationPreferences.isEnabled else { return }

        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(BackgroundAutomationPreferences.interval.rawValue))

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Logger.misc.error("Failed to schedule automation: \(error.localizedDescription)")
        }
    }
	
	@available(iOS 19.0, *)
	private func _handleContinuedProcessing(task: BGContinuedProcessingTask) {
        // Progress reporting is required by the system for a continued-processing task.
        task.progress.totalUnitCount = 100

        // Expiration here does not pause: BGContinuedProcessingTask exists precisely so the user's
        // download can finish after backgrounding, and DownloadManager already owns pause/resume.
        //
        // Order matters. The handler cancels the monitor first and only then asks ownership to
        // complete: if a monitor was running, its cancellation path closes the gate and
        // `ownership.expired()` is a no-op; if the main-actor hop never ran, no monitor exists and
        // ownership completes instead. Either way exactly one completion, and always one.
        let gate = BackgroundTaskCompletionGate { success in
            task.setTaskCompleted(success: success)
        }
        let cancellation = BackgroundWorkCancellation()
        let ownership = BackgroundTaskOwnership(gate: gate)

        // Wire expiration before the main-actor runner exists: a BGTaskScheduler handler is not
        // async, and expiration must be able to cancel the monitor synchronously. If the main-actor
        // hop never runs, `expired()` also completes the task — otherwise nobody would.
        task.expirationHandler = {
            cancellation.cancel()
            ownership.expired()
        }

        Task { @MainActor in
            let runner = BackgroundDownloadRunner(
                gate: gate,
                monitor: DownloadManagerBackgroundMonitor(),
                cancellation: cancellation,
                // The previous implementation had no deadline and could poll until the system
                // killed it. A continued-processing task gets a bounded window, so keep one
                // explicit.
                timeout: 15 * 60,
                pollInterval: 2,
                ownership: ownership,
                onProgress: { work in
                    task.progress.completedUnitCount = work.completedPercent
                }
            )
            runner.start()
        }
    }

	// iOS 17 and below.
	private func _handleBackgroundDownload(task: BGProcessingTask) {
        // No progress reporting here: `progress` is a BGContinuedProcessingTask member only.
        // A BGProcessingTask is either running or not, and the system measures it by its own
        // budget rather than by a counter we publish.
        let gate = BackgroundTaskCompletionGate { success in
            task.setTaskCompleted(success: success)
        }
        let cancellation = BackgroundWorkCancellation()
        let ownership = BackgroundTaskOwnership(gate: gate)

        // Expiration cancels the monitor. The monitor pauses downloads on its way out and closes
        // the gate with failure; because the gate is single-owner, this can no longer contradict
        // a success the worker already reported. `expired()` runs second and covers the case where
        // the main-actor hop never ran at all, so no monitor exists to close anything.
        task.expirationHandler = {
            cancellation.cancel()
            ownership.expired()
        }

        Task { @MainActor in
            let runner = BackgroundDownloadRunner(
                gate: gate,
                monitor: DownloadManagerBackgroundMonitor(),
                cancellation: cancellation,
                timeout: 4 * 60,
                // Losing background time here means the system will suspend the transfer anyway;
                // leave the downloads paused and resumable rather than half-alive.
                pauseOnCancellation: true,
                ownership: ownership
            )
            runner.start()
        }
    }
	
	private func _handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Same single-owner rule as the download handlers: the body and the expiration handler
        // both used to call setTaskCompleted, so an expiration landing between them reported
        // failure and then success for one task.
        let gate = BackgroundTaskCompletionGate { success in
            task.setTaskCompleted(success: success)
        }

        // This handler's whole body is one main-actor hop, so the hop itself is the thing that can
        // be lost: if the app is suspended before it runs, an expiration-only handler would leave
        // the task uncompleted. The refresh work is idempotent and cheap, so let expiration finish
        // it directly rather than relying on ownership tracking.
        task.expirationHandler = {
            gate.finish(success: false, source: .expiration)
        }

        // The launch handler is not guaranteed to run on the main actor, and `downloads` is
        // main-actor UI state; read it there.
        let monitor = DownloadManagerBackgroundMonitor()
        Task { @MainActor in
            // Schedule a processing task if downloads are still pending.
            if monitor.currentWork().hasUnfinishedWork {
                self._scheduleBackgroundDownloadTask()
            }
            gate.finish(success: true)
        }
    }

    func _scheduleBackgroundDownloadTask() {
        guard EmbeddedContainerRuntime.supportsScheduledGuestTasks else { return }
        let request = BGProcessingTaskRequest(identifier: "com.vexsign.background.download")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
        }
    }

    // iOS 19+: for active foreground downloads that may be backgrounded.
    @available(iOS 19.0, *)
    func submitContinuedProcessingTask() {
        guard EmbeddedContainerRuntime.supportsScheduledGuestTasks else { return }
        let activeDownloads = DownloadManager.shared.downloads.filter {
            $0.isActive || ($0.progress > 0 && $0.progress < 1.0)
        }

        guard !activeDownloads.isEmpty else { return }

        let count = activeDownloads.count
        let request = BGContinuedProcessingTaskRequest(
            identifier: "com.vexsign.background.download.continued",
            title: "Downloading Apps",
            subtitle: "Processing \(count) item(s)"
        )

        // .queue lets the task continue if backgrounded.
        request.strategy = .queue

        if BGTaskScheduler.supportedResources.contains(.gpu) {
            request.requiredResources = .gpu
        }

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Logger.misc.error("Failed to submit BGContinuedProcessingTask: \(error.localizedDescription)")
        }
    }
}
