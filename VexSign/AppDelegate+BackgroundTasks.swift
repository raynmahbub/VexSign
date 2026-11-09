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
        // Runs in background; DownloadManager already handles Live Activity updates.
        var wasExpired = false

        task.expirationHandler = {
            wasExpired = true
            // Don't pause — let DownloadManager handle continuation.
            task.setTaskCompleted(success: false)
        }

        // Progress tracking is required by the system.
        let progress = task.progress
        progress.totalUnitCount = 100

        DispatchQueue.global(qos: .userInitiated).async {
            while !wasExpired && !DownloadManager.shared.downloads.isEmpty {
                let activeDownloads = DownloadManager.shared.downloads.filter {
                    $0.isActive || ($0.progress > 0 && $0.progress < 1.0 && !$0.isPaused)
                }

                if activeDownloads.isEmpty {
                    progress.completedUnitCount = 100
                    break
                }

                let totalProgress = activeDownloads.reduce(0.0) { $0 + $1.progress }
                let averageProgress = activeDownloads.isEmpty ? 1.0 : totalProgress / Double(activeDownloads.count)
                progress.completedUnitCount = Int64(averageProgress * 100)

                Thread.sleep(forTimeInterval: 2.0)
            }

            task.setTaskCompleted(success: !wasExpired && DownloadManager.shared.downloads.isEmpty)
        }
    }

	// iOS 17 and below.
	private func _handleBackgroundDownload(task: BGProcessingTask) {
        task.expirationHandler = {
            DownloadManager.shared.pauseAllDownloads()
            task.setTaskCompleted(success: false)
        }

        DownloadManager.shared.resumeAllDownloads()

        let timeout: TimeInterval = 4 * 60
        let startTime = Date()

        DispatchQueue.global().async {
            while !DownloadManager.shared.downloads.isEmpty {
                if Date().timeIntervalSince(startTime) > timeout {
                    break
                }
                Thread.sleep(forTimeInterval: 5.0)
            }
            task.setTaskCompleted(success: true)
        }
    }
	
	private func _handleBackgroundRefresh(task: BGAppRefreshTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        // Schedule a processing task if downloads are still pending.
        if !DownloadManager.shared.downloads.isEmpty {
            _scheduleBackgroundDownloadTask()
        }

        task.setTaskCompleted(success: true)
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
