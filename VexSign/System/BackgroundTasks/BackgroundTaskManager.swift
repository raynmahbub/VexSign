//
//  BackgroundTaskManager.swift
//  VexSign
//
//  Created by VexSign Team on 13.10.2025.
//

import Foundation
import UIKit
import UserNotifications

/// Best-effort background assertion for an in-flight operation.
///
/// This used to play silent audio to keep the process alive. VexSign is not an audio
/// app, so declaring `UIBackgroundModes: audio` for that purpose is an App Store
/// rejection risk and an audio interruption could end the keep-alive mid-operation.
/// The manager now relies only on `UIApplication.beginBackgroundTask`: it renews the
/// assertion while work is active, posts an expiration notice, and the caller
/// reconciles on return to the foreground. No claim is made that iOS cannot suspend
/// the app.
final class BackgroundTaskManager {

	private var backgroundTaskID: UIBackgroundTaskIdentifier?
	private var cycleTimer: Timer?
	private var isRunning = false
    private let expirationEvent = Notification.Name("VexSign.backgroundTask.expired.\(UUID().uuidString)")

	private let taskName: String
	private let expirationNotificationTitle: String
	private let expirationNotificationBody: String

	init(
		taskName: String,
		expirationTitle: String = "Task continuing",
		expirationBody: String = "The task will continue when you reopen the app"
	) {
		self.taskName = taskName
		self.expirationNotificationTitle = expirationTitle
		self.expirationNotificationBody = expirationBody
	}

	func start() {
		guard !isRunning else { return }
		isRunning = true

        NotificationCenter.default.addObserver(self, selector: #selector(handleExpiration), name: expirationEvent, object: nil)
		startBackgroundCycle()
	}

	func stop() {
		guard isRunning else { return }
		isRunning = false

        NotificationCenter.default.removeObserver(self, name: expirationEvent, object: nil)
		cycleTimer?.invalidate()
		cycleTimer = nil
		stopBackgroundTask()
	}

	/// Renewing the assertion on a timer is only a best-effort extension. iOS may still
	/// suspend the app; the operation's own recovery path owns the final result.
	private func startBackgroundCycle() {
		cycleTimer?.invalidate()
		// A main-run-loop timer keeps UIApplication's background assertion on the
		// main actor without capturing a weak `self` in a @Sendable Task. Swift 6
		// rejected that capture, and a background-thread assertion was never valid.
		let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
			self?.renewBackgroundTask()
		}
		RunLoop.main.add(timer, forMode: .common)
		cycleTimer = timer
	}

	private func renewBackgroundTask() {
		guard isRunning else { return }
		stopBackgroundTask()
		let event = expirationEvent
		backgroundTaskID = UIApplication.shared.beginBackgroundTask {
			NotificationCenter.default.post(name: event, object: nil)
		}
	}

    @objc private func handleExpiration() {
        guard isRunning else { return }
        sendExpirationNotification()
        startBackgroundCycle()
	}

	private func stopBackgroundTask() {
		if let taskID = backgroundTaskID {
			UIApplication.shared.endBackgroundTask(taskID)
			backgroundTaskID = nil
		}
	}

	private func sendExpirationNotification() {
		let note = VexSignNotification(
			identifier: "com.vexsign.background.expiration.\(VexSignNotificationService.digest(taskName))",
			topic: .downloads,
			title: expirationNotificationTitle,
			body: expirationNotificationBody,
			category: .task,
			details: [NotificationPayloadKey.route.rawValue: "tasks"]
		)
		Task { @MainActor in
			await VexSignNotificationService.shared.post(note, dedupeContentKey: taskName)
		}
	}

	deinit {
		stop()
	}
}
