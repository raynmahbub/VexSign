//
//  DownloadManager.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 3.05.2025.
//

import Foundation
import Combine
import UIKit
import UserNotifications
import BackgroundTasks
import ActivityKit
import NimbleExtensions

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()

	protocol ErrorDelegate: AnyObject {
		func showUIErrorMessage(title: String, message: String)

		/// The same message with one explicit choice. Used where doing nothing is not a safe default
		/// — a download that failed its integrity check has a file on disk that has to be either
		/// imported deliberately or deleted.
		func showUIErrorMessage(
			title: String,
			message: String,
			actionTitle: String,
			action: @escaping () -> Void,
			dismissTitle: String,
			onDismiss: (() -> Void)?
		)
	}
	weak var errorDelegate: ErrorDelegate?
	
	@Published var downloads: [Download] = []
	@Published var currentDownloadSpeed: Int64 = 0

	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}

	var activeNetworkDownloads: [Download] {
		downloads.filter { !$0.onlyArchiving && ($0.isActive || $0.progress > 0) && $0.progress < 1.0 && !$0.isPaused }
	}

	/// Unpacking or auto signing. Both hold the keep-alive open.
	var processingDownloads: [Download] {
		downloads.filter { $0.phase == .importing || $0.phase == .signing }
	}

	var hasUnfinishedWork: Bool {
		downloads.contains { $0.isActive || $0.isImporting || $0.isSigning || ($0.progress > 0 && $0.progress < 1.0) }
	}

	var _backgroundSession: URLSession!
	var _foregroundSession: URLSession!
	var backgroundCompletionHandler: (() -> Void)?

	var isAppInBackground = false
	var backgroundEntryTime: Date?

	var backgroundTaskManager: BackgroundTaskManager?
	private var importObservers: [String: AnyCancellable] = [:]
	var progressUpdateTimer: Timer?

	// `Any?` so the property carries no availability requirement (ActivityKit is 16.1+, app deploys to 16.0).
	var downloadActivity: Any?

	@available(iOS 16.2, *)
	var _downloadActivity: Activity<DownloadActivityAttributes>? {
		get { downloadActivity as? Activity<DownloadActivityAttributes> }
		set { downloadActivity = newValue }
	}
	var lastUpdateTime: Date = Date()
	var updateThrottle: TimeInterval = 2.0

	/// Makes the next Live Activity / progress notification skip the update throttle.
	func forceNextProgressUpdate() { lastUpdateTime = .distantPast }
	var activityStateTask: Task<Void, Never>?
	// Guards the race where a Live Activity is mid-creation (`downloadActivity == nil`) and the
	// progress timer would otherwise post a fallback notification.
	var isCreatingLiveActivity = false

	private var speedTracker = DownloadSpeedTracker()

	var completedDownloadNames: [String] = []
	var isActivityShowingCompletion = false

	// Every download in this Live Activity session, incl. ones downloaded but not yet archived.
	var allActivityDownloads: [String: (fileName: String, downloaded: Int64, total: Int64)] = [:]

	// Downloads that finished downloading (X in the X/Y counter) — distinct from archiving completion.
	var finishedDownloadingIDs: Set<String> = []

	override init() {
		super.init()

		let foregroundConfig = URLSessionConfiguration.default
		foregroundConfig.timeoutIntervalForRequest = 300 // 5 min
		foregroundConfig.timeoutIntervalForResource = 7200 // 2 hours
		foregroundConfig.httpShouldUsePipelining = true
		foregroundConfig.allowsExpensiveNetworkAccess = true
		foregroundConfig.allowsConstrainedNetworkAccess = true
		foregroundConfig.httpMaximumConnectionsPerHost = 10
		foregroundConfig.multipathServiceType = .handover
		foregroundConfig.waitsForConnectivity = false

		_foregroundSession = URLSession(configuration: foregroundConfig, delegate: self, delegateQueue: nil)

		let backgroundConfig: URLSessionConfiguration = URLSessionConfiguration.background(withIdentifier: "com.vexsign.app.background")
		backgroundConfig.isDiscretionary = false // don't wait for ideal conditions
		backgroundConfig.sessionSendsLaunchEvents = true
		backgroundConfig.shouldUseExtendedBackgroundIdleMode = false
		backgroundConfig.timeoutIntervalForRequest = 300 // 5 min
		backgroundConfig.timeoutIntervalForResource = 7200 // 2 hours
		backgroundConfig.httpShouldUsePipelining = true
		backgroundConfig.allowsExpensiveNetworkAccess = true
		backgroundConfig.allowsConstrainedNetworkAccess = true
		backgroundConfig.httpMaximumConnectionsPerHost = 10
		backgroundConfig.waitsForConnectivity = false
		backgroundConfig.networkServiceType = .responsiveData

		_backgroundSession = URLSession(configuration: backgroundConfig, delegate: self, delegateQueue: nil)

		requestNotificationPermissions()

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(appWillEnterBackground),
			name: UIApplication.willResignActiveNotification,
			object: nil
		)
		
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(appDidBecomeActive),
			name: UIApplication.didBecomeActiveNotification,
			object: nil
		)
		
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(appWillTerminate),
			name: UIApplication.willTerminateNotification,
			object: nil
		)

		// Live Activity control notifications from the widget extension.
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handlePauseDownloadsNotification),
			name: NSNotification.Name("PauseDownloads"),
			object: nil
		)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleResumeDownloadsNotification),
			name: NSNotification.Name("ResumeDownloads"),
			object: nil
		)
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}
	
	// Audio sessions can only be activated while the app is still foreground.
	private func ensureKeepAlive() {
		guard backgroundTaskManager == nil else { return }

		let manager = BackgroundTaskManager(
			taskName: "DownloadManager",
			expirationTitle: "Downloads continuing",
			expirationBody: "Downloads and imports continue in the background"
		)
		manager.start()
		backgroundTaskManager = manager
		startProgressTimer()
	}

	private func releaseKeepAliveIfIdle() {
		guard !hasUnfinishedWork else { return }
		backgroundTaskManager?.stop()
		backgroundTaskManager = nil
		endProgressTimer()
	}

	func beginImport(for download: Download) {
		download.beginImport()

		// Unpacking has no session callbacks to piggyback on.
		importObservers[download.id] = download.$unpackageProgress
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in
				self?.updateLiveActivity(activeDownloads: [])
			}

		if isAppInBackground { ensureKeepAlive() }
	}

	func endImport(for download: Download) {
		importObservers.removeValue(forKey: download.id)
		download.endImport()
	}

	private func requestNotificationPermissions() {
		// The prompt is the whole point; the answer is read back from
		// `getNotificationSettings` when the UI actually needs it.
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .providesAppNotificationSettings]) { _, _ in }
		
		UNUserNotificationCenter.current().delegate = self
	}
	
	@objc private func appWillEnterBackground() {
		isAppInBackground = true
		backgroundEntryTime = Date()

		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			guard let self = self else { return }

			guard self.hasUnfinishedWork else { return }

			DispatchQueue.main.async {
				self.ensureKeepAlive()
			}
		}
	}

	@objc private func appDidBecomeActive() {
		consumeWidgetDownloadControl()
		isAppInBackground = false
		backgroundEntryTime = nil

		backgroundTaskManager?.stop()
		backgroundTaskManager = nil

		UNUserNotificationCenter.current().removeAllDeliveredNotifications()

		let hasActiveDownloads = downloads.contains { download in
			(download.isActive && !download.isPaused) ||
			(download.progress > 0 && download.progress < 1.0 && !download.isPaused) ||
			(download.unpackageProgress > 0 && download.unpackageProgress < 1.0)
		}

		let hasPausedDownloads = downloads.contains { download in
			download.isPaused && download.progress > 0 && download.progress < 1.0
		}

		if downloadActivity != nil && !hasActiveDownloads && !hasPausedDownloads && processingDownloads.isEmpty {
			dismissLiveActivityImmediately()
			completedDownloadNames = []
			isActivityShowingCompletion = false
			allActivityDownloads = [:] 
			finishedDownloadingIDs = []
		}

		processPendingDownloads()

		for download in downloads where download.isPaused {
			resumeDownload(download)
		}

		let pausedDownloads = downloads.filter { $0.isPaused }
		if !pausedDownloads.isEmpty && downloadActivity != nil {
			let activeDownloads = self.downloads.filter {
				($0.progress > 0 && $0.progress < 1.0) ||
				($0.unpackageProgress > 0 && $0.unpackageProgress < 1.0)
			}
			if !activeDownloads.isEmpty {
				self.forceNextProgressUpdate()
				self.updateLiveActivity(activeDownloads: activeDownloads)
			}
		}
	}
	
	@objc private func handlePauseDownloadsNotification() {
		DispatchQueue.main.async {
			self.pauseAllDownloads()
		}
	}

	@objc private func handleResumeDownloadsNotification() {
		DispatchQueue.main.async {
			self.resumeAllDownloads()
		}
	}

	/// Handles commands written by a Live Activity intent in the widget
	/// extension. This is polled by the existing progress timer and on app
	/// activation, so Stop works even when VexSign is not the foreground app.
	private func consumeWidgetDownloadControl() {
		guard let command = WidgetStatusPayload.consumeDownloadControl() else { return }
		switch command {
		case "pause": pauseAllDownloads()
		case "resume": resumeAllDownloads()
		case "stop": cancelAllDownloads()
		default: break
		}
	}

	@objc private func appWillTerminate() {
		// Must finish fast (synchronous, time-limited) to avoid watchdog termination.
		backgroundTaskManager?.stop()
		backgroundTaskManager = nil

		endProgressTimer()

		if #available(iOS 16.2, *), let activity = _downloadActivity {
			Task {
				await activity.end(nil, dismissalPolicy: .immediate)
			}
			downloadActivity = nil
		}

		let saveGroup = DispatchGroup()
		let deadline = DispatchTime.now() + .milliseconds(500)

		for download in downloads {
			if let task = download.task, task.state == .running {
				saveGroup.enter()
				task.cancel { resumeData in
					download.resumeData = resumeData
					self.saveResumeData(for: download)
					saveGroup.leave()
				}
			}
		}

		_ = saveGroup.wait(timeout: deadline)
	}
	
	private func startProgressTimer() {
		guard progressUpdateTimer == nil else { return }

		let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
			self?.handleProgressTick()
		}

		RunLoop.main.add(timer, forMode: .common)
		progressUpdateTimer = timer
	}

	private func endProgressTimer() {
		progressUpdateTimer?.invalidate()
		progressUpdateTimer = nil
	}

	private func handleProgressTick() {
		consumeWidgetDownloadControl()
		sampleDownloadSpeed()

		if isAppInBackground {
			updateMergedProgressNotification()
		} else if activeNetworkDownloads.isEmpty && processingDownloads.isEmpty {
			endProgressTimer()
		}
	}

	private func sampleDownloadSpeed() {
		guard !activeNetworkDownloads.isEmpty else {
			speedTracker.reset()
			if currentDownloadSpeed != 0 { currentDownloadSpeed = 0 }
			return
		}

		// Finished downloads stay in the sum to keep the total monotonic.
		let totalBytes = downloads.reduce(Int64(0)) { $0 + ($1.onlyArchiving ? 0 : $1.bytesDownloaded) }
		let speed = speedTracker.sample(totalBytes: totalBytes)
		if currentDownloadSpeed != speed { currentDownloadSpeed = speed }
	}
	
	private func processPendingDownloads() {
		for download in downloads where !download.isImporting {
			guard let pendingURL = download.pendingFileURL else { continue }
			try? handlePackageFile(url: pendingURL, dl: download)
		}
	}
	
	func saveResumeData(for download: Download) {
		guard let resumeData = download.resumeData else { return }
		
		let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		let resumeDataPath = documentsPath.appendingPathComponent("ResumeData_\(download.id).data")
		
		try? resumeData.write(to: resumeDataPath)
	}
	
	private func loadResumeData(for download: Download) -> Data? {
		let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		let resumeDataPath = documentsPath.appendingPathComponent("ResumeData_\(download.id).data")
		
		return try? Data(contentsOf: resumeDataPath)
	}
	
	// MARK: - Notification Methods

	func updateMergedProgressNotification() {
		// Actively downloading only — archiving doesn't show progress notifications.
		let activeDownloads = downloads.filter {
			(($0.isActive || $0.progress > 0) && $0.progress < 1.0 && !$0.isPaused)
		}

		let pausedDownloads = downloads.filter {
			$0.progress > 0 && $0.progress < 1.0 && $0.isPaused
		}

		guard !activeDownloads.isEmpty || !pausedDownloads.isEmpty else {
			UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["merged_download_progress"])

			guard processingDownloads.isEmpty else {
				updateLiveActivity(activeDownloads: [])
				return
			}

			endLiveActivity()

			releaseKeepAliveIfIdle()

			return
		}

		// Imports (onlyArchiving) are excluded — no network bytes, they'd show a phantom 0% entry.
		if activeDownloads.isEmpty && !pausedDownloads.isEmpty {
			updateLiveActivityWithPausedState(activeDownloads: pausedDownloads)
		} else {
			let downloadingOnly = downloads.filter { !$0.onlyArchiving && $0.progress > 0 && $0.progress < 1.0 && !$0.isPaused }
			updateLiveActivity(activeDownloads: downloadingOnly)
		}

		// Live Activities are the primary progress UI; only fall back to a local notification when
		// they're genuinely unavailable. (Don't branch on `downloadActivity != nil` — it's
		// momentarily false mid-creation, which would race a stray notification onscreen.)
		if #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled {
			if downloadActivity == nil && !isCreatingLiveActivity {
				startLiveActivityIfNeeded()
			}
			UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["merged_download_progress"])
			return
		}

		// Network downloads only — imports must not produce a stuck 0% notification.
		let notifiableDownloads = activeDownloads.filter { !$0.onlyArchiving }
		guard !notifiableDownloads.isEmpty else {
			UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["merged_download_progress"])
			return
		}

		let content = UNMutableNotificationContent()

		if notifiableDownloads.count == 1 {
			let download = notifiableDownloads[0]
			let percent = Int(download.progress * 100)
			let bytesFormatted = formatBytes(download.bytesDownloaded)
			let totalFormatted = formatBytes(download.totalBytes)

			content.title = download.fileName
			content.body = "\(bytesFormatted) / \(totalFormatted)"
			content.subtitle = "Progress: \(percent)%"
		} else {
			let totalProgress = notifiableDownloads.reduce(0.0) { $0 + $1.progress }
			let averageProgress = totalProgress / Double(notifiableDownloads.count)
			let percent = Int(averageProgress * 100)

			let totalBytesDownloaded = notifiableDownloads.reduce(Int64(0)) { $0 + $1.bytesDownloaded }
			let totalBytesExpected = notifiableDownloads.reduce(Int64(0)) { $0 + $1.totalBytes }

			let bytesFormatted = formatBytes(totalBytesDownloaded)
			let totalFormatted = formatBytes(totalBytesExpected)

			content.title = "Downloading \(notifiableDownloads.count) files"
			content.subtitle = "Overall Progress: \(percent)%"
			content.body = "\(bytesFormatted) / \(totalFormatted)"
		}

		content.sound = nil
		content.interruptionLevel = .passive

		let request = UNNotificationRequest(
			identifier: "merged_download_progress",
			content: content,
			trigger: nil
		)

		UNUserNotificationCenter.current().add(request)
	}
	
	func sendSystemNotification(title: String, body: String, identifier: String) {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		
		let request = UNNotificationRequest(
			identifier: identifier,
			content: content,
			trigger: nil
		)
		
		UNUserNotificationCenter.current().add(request)
	}
	
	func sendCompletionNotification(for download: Download, status: String) {
		let content = UNMutableNotificationContent()
		content.title = status
		content.body = download.fileName
		content.sound = .default
		content.interruptionLevel = .timeSensitive
		
		let request = UNNotificationRequest(
			identifier: "completion_\(download.id)",
			content: content,
			trigger: nil
		)
		
		UNUserNotificationCenter.current().add(request)
	}

	func showUIErrorMessage(for download: Download, error: NSError) {
		DispatchQueue.main.async {
			let generator = UINotificationFeedbackGenerator()
			generator.notificationOccurred(.error)

			self.errorDelegate?.showUIErrorMessage(
				title: "Failed to download ipa",
				message: error.localizedDescription
			)
		}
	}
	
	// MARK: - Helper Methods
	
	private func formatBytes(_ bytes: Int64) -> String {
		let formatter = ByteCountFormatter()
		formatter.countStyle = .binary
		return formatter.string(fromByteCount: bytes)
	}
	
	// MARK: - Public Methods
	
	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		appName: String? = nil,
		appDescription: String? = nil,
		integrity: DownloadIntegrity.Expectation? = nil
	) -> Download {
		// Game Mode (Settings → Game Mode): the one place every download funnels through, so
		// nothing reaches the network while it is on. Callers discard the return value, and
		// an unstarted download is never appended to `downloads`, so the UI stays on "Get".
		if GameMode.isEnabled {
			Task { @MainActor in GameMode.reportBlocked(.localized("Downloading")) }
			return Download(id: id, url: url, appName: appName, appDescription: appDescription, integrity: integrity)
		}

		if DownloadPreferences.wifiOnly, DownloadPreferences.isOnExpensivePath {
			Task { @MainActor in
				Toast.error(.localized("Wi-Fi only is on. Connect to Wi-Fi or turn the setting off."), duration: .long)
			}
			return Download(id: id, url: url, appName: appName, appDescription: appDescription, integrity: integrity)
		}

		if DownloadPreferences.chargeOnly, !DownloadPreferences.isCharging {
			Task { @MainActor in
				Toast.error(.localized("Charge only is on. Plug in your device or turn the setting off."), duration: .long)
			}
			return Download(id: id, url: url, appName: appName, appDescription: appDescription, integrity: integrity)
		}

		let running = downloads.filter { !$0.onlyArchiving && ($0.isActive || $0.progress > 0) && $0.progress < 1.0 && !$0.isPaused }.count
		if running >= DownloadPreferences.maxParallel {
			Task { @MainActor in
				Toast.info(.localized("Waiting for a download slot (%lld max).", arguments: DownloadPreferences.maxParallel), systemImage: "arrow.down.circle")
			}
		}

        if let existingDownload = downloads.first(where: { $0.url == url }) {
            // Same URL: keep the row, but take the promise this call was given (a later source
            // fetch may know a size the first one did not).
            if let integrity {
                existingDownload.integrity = integrity
            }
            resumeDownload(existingDownload)
            return existingDownload
        }

        let download = Download(id: id, url: url, appName: appName, appDescription: appDescription, integrity: integrity)
        download.isActive = true

		let session = isAppInBackground ? _backgroundSession! : _foregroundSession!

		var request = URLRequest(url: url)
		request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		request.networkServiceType = .responsiveData
		request.allowsExpensiveNetworkAccess = !DownloadPreferences.wifiOnly
		request.allowsConstrainedNetworkAccess = !DownloadPreferences.wifiOnly
		request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")

		// Auth headers for premium sources.
		VexSignAPI.applyAuthHeaders(to: &request)

		let task = session.downloadTask(with: request)
		download.task = task
		task.priority = 1.0
		task.resume()

		DispatchQueue.main.async {
			self.objectWillChange.send()
			self.downloads.append(download)

			self.startProgressTimer()

			if self.isAppInBackground {
				self.ensureKeepAlive()
			}

			// BGContinuedProcessingTask keeps work going in the background on iOS 19+.
			if #available(iOS 19.0, *) {
				if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
					appDelegate.submitContinuedProcessingTask()
				}
			}

			Task {
				self.startLiveActivityIfNeeded()
			}
		}

		return download
	}
	
	func startArchive(from url: URL, id: String = UUID().uuidString, appName: String? = nil, reviewDuplicates: Bool = false, completion: ((Error?) -> Void)? = nil) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true, appName: appName)
		download.isActive = true

		DispatchQueue.main.async {
			self.objectWillChange.send()
			self.downloads.append(download)
			self.beginImport(for: download)
		}

		DispatchQueue.global().async {
			FR.handlePackageFile(url, download: download) { result in
				switch result {
				case .failure(let error):
					UINotificationFeedbackGenerator().notificationOccurred(.error)

					if let completion = completion {
						// Caller owns the error UI; don't also fire the generic delegate alert.
						DispatchQueue.main.async { completion(error) }
					} else if !self.isAppInBackground {
						self.errorDelegate?.showUIErrorMessage(
							title: "Import Failed",
							message: error.localizedDescription
						)
					}

					DispatchQueue.main.async { self.finishImport(of: download, succeeded: false) }
				case .success(let app):
					DispatchQueue.main.async {
						self.objectWillChange.send()
						download.unpackageProgress = 1.0
                        if reviewDuplicates {
                            ImportDuplicateReview.resolve(app) { chosen, retainedNewCopy in
                                completion?(nil)
                                if retainedNewCopy {
                                    Toast.success(.localized("Added to Library"), systemImage: "archivebox")
                                    self.autoSignOrFinish(chosen, for: download)
                                } else {
                                    Toast.info(.localized("Using existing Library copy"), systemImage: "archivebox")
                                    self.finishImport(of: download, succeeded: true)
                                }
                            }
                        } else {
                            completion?(nil)
                            self.autoSignOrFinish(app, for: download)
                        }
					}
				}
			}
		}

		return download
	}
	
	func resumeDownload(_ download: Download) {
		// Game Mode pauses downloads on purpose; the automatic paths (becoming active again,
		// a background task waking up) must not quietly undo that.
		guard !GameMode.isEnabled else { return }

		if download.resumeData == nil {
			download.resumeData = loadResumeData(for: download)
		}
		
		let session = (isAppInBackground ? _backgroundSession : _foregroundSession) ?? URLSession.shared
		
		if let resumeData = download.resumeData {
			let task = session.downloadTask(withResumeData: resumeData)
			download.task = task
			task.resume()
			download.isActive = true
			download.isPaused = false
		} else {
			let url = download.task?.originalRequest?.url ?? download.url
			var request = URLRequest(url: url)
			VexSignAPI.applyAuthHeaders(to: &request)
			let task = session.downloadTask(with: request)
			download.task = task
			task.resume()
			download.isActive = true
			download.isPaused = false
		}
		
		DispatchQueue.main.async {
			self.startProgressTimer()

			let activeDownloads = self.downloads.filter {
				($0.progress > 0 && $0.progress < 1.0) ||
				($0.unpackageProgress > 0 && $0.unpackageProgress < 1.0)
			}
			if !activeDownloads.isEmpty && self.downloadActivity != nil {
				self.forceNextProgressUpdate()
				self.updateLiveActivity(activeDownloads: activeDownloads)
			}
		}
	}

	func pauseDownload(_ download: Download) {
		download.task?.cancel { resumeData in
			download.resumeData = resumeData
			self.saveResumeData(for: download)
		}
		download.isPaused = true
		download.isActive = false
	}
	
	func cancelDownload(_ download: Download) {
		download.task?.cancel()
		download.isActive = false

		let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		let resumeDataPath = documentsPath.appendingPathComponent("ResumeData_\(download.id).data")
		try? FileManager.default.removeItem(at: resumeDataPath)

		DispatchQueue.main.async {
			if let index = self.downloads.firstIndex(where: { $0.id == download.id }) {
				self.objectWillChange.send()

				// Drop from tracking so a manually stopped download leaves overall progress.
				self.allActivityDownloads.removeValue(forKey: download.id)
				self.finishedDownloadingIDs.remove(download.id)

				self.downloads.remove(at: index)

				let remainingActiveDownloads = self.downloads.filter {
					$0.progress > 0 && $0.progress < 1.0 && !$0.isPaused
				}

				if !remainingActiveDownloads.isEmpty && self.downloadActivity != nil {
					self.forceNextProgressUpdate()
					self.updateLiveActivity(activeDownloads: remainingActiveDownloads)
				} else {
					self.endLiveActivity()
				}

				self.releaseKeepAliveIfIdle()
			}
		}
	}
	
	/// Stops every network/import job represented by the current Live Activity.
	/// Unlike pause, this removes the jobs from the queue and immediately ends
	/// the Dynamic Island activity.
	func cancelAllDownloads() {
		let currentDownloads = downloads.filter { $0.isActive || $0.isPaused || $0.isImporting || $0.isSigning }
		for download in currentDownloads {
			cancelDownload(download)
		}
	}

	func pauseAllDownloads() {
		let currentDownloads = downloads.filter {
			$0.isActive || ($0.progress > 0 && $0.progress < 1.0) || $0.isImporting || $0.isSigning
		}
		for download in currentDownloads {
			pauseDownload(download)
		}
		
		DispatchQueue.main.async {
			let activeDownloads = self.downloads.filter {
				($0.progress > 0 && $0.progress < 1.0) ||
				($0.unpackageProgress > 0 && $0.unpackageProgress < 1.0)
			}
			if !activeDownloads.isEmpty && self.downloadActivity != nil {
				self.forceNextProgressUpdate()
				self.updateLiveActivity(activeDownloads: activeDownloads)
			}
		}
	}
	
	func resumeAllDownloads() {
		// Resuming is user-initiated here (button, Live Activity, Shortcut), so say why
		// nothing happened instead of leaving the button looking broken.
		guard !GameMode.isEnabled else {
			let paused = downloads.filter { $0.isPaused && $0.progress > 0 && $0.progress < 1.0 }
			if !paused.isEmpty, !isAppInBackground {
				Task { @MainActor in
					GameMode.reportBlockedInline(.localized("Resuming downloads"))
				}
			}
			return
		}

		for download in downloads where download.isPaused {
			resumeDownload(download)
		}

		if isAppInBackground && hasUnfinishedWork {
			ensureKeepAlive()
		}
	}
	
	func isManualDownload(_ string: String) -> Bool {
		return string.contains("VexSignManualDownload")
	}
	
	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}
	
	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}
	
	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}
	
	var nonManualDownloads: [Download] {
		downloads.filter { !isManualDownload($0.id) }
	}

	func handlePackageFile(url: URL, dl: Download) throws {
		guard !dl.isImporting else { return }

		let expectation = dl.integrity ?? DownloadIntegrity.Expectation()
		guard !expectation.isEmpty else {
			// Nothing was declared for this file: import it, and say what it was, exactly as before.
			beginPackageImport(url: url, dl: dl)
			return
		}

		// when the source declared a size (or a hash), check the file before anything is
		// unpacked. A truncated IPA used to reach the importer and fail there, with a message that
		// said nothing about the download. Reading and hashing a large file off the main thread
		// keeps the row responsive; the import itself only starts once the verdict is in.
		DispatchQueue.global(qos: .utility).async { [weak self] in
			let verdict = DownloadIntegrity.verify(fileAt: url, expectation: expectation)

			DispatchQueue.main.async {
				guard let self else { return }

				switch verdict {
				case .verified(let checks):
					SigningLog.shared.info(
						.localized("%@ matches all %lld check(s) the source published.", arguments: dl.fileName, checks),
						category: "download"
					)
					self.beginPackageImport(url: url, dl: dl)

				case .unverified:
					self.beginPackageImport(url: url, dl: dl)

				case .mismatch(let failures):
					let message = DownloadIntegrity.describe(failures, fileName: dl.fileName)
					SigningLog.shared.error(message, category: "download")

					// A failed check is a failed import: the row goes away, as it does for any other
					// failure. The one deliberate override therefore has to be offered here, in the
					// alert that reports the mismatch — see `presentIntegrityFailure`.
					self.finishImport(of: dl, succeeded: false)
					self.presentIntegrityFailure(for: dl, failures: failures, message: message, fileURL: url)
				}
			}
		}
	}

	/// Asks the user what to do with a file that did not match its source.
	///
	/// Two outcomes, both final for this file: import it deliberately, or delete it. There is no
	/// "dismiss and see" — leaving a rejected package on disk is how a stray file gets imported
	/// later by something that is not this alert.
	private func presentIntegrityFailure(
		for dl: Download,
		failures: [DownloadIntegrity.Failure],
		message: String,
		fileURL: URL
	) {
		guard !isAppInBackground else {
			// Nobody to ask: discard it, and say so.
			discardRejectedPackage(at: fileURL, fileName: dl.fileName)
			sendCompletionNotification(for: dl, status: "❌ " + .localized("Download failed a check"))
			return
		}

		dl.retainedPackageURL = fileURL

		errorDelegate?.showUIErrorMessage(
			title: .localized("Download failed a check"),
			message: message,
			actionTitle: .localized("Import Anyway"),
			action: { [weak self, weak dl] in
				guard let self, let dl else { return }
				self.importAnyway(dl, failures: failures)
			},
			dismissTitle: .localized("Delete"),
			onDismiss: { [weak self, weak dl] in
				guard let self, let dl else { return }
				dl.retainedPackageURL = nil
				self.discardRejectedPackage(at: fileURL, fileName: dl.fileName)
			}
		)
	}

	/// Imports a download the user has explicitly accepted despite a failed integrity check.
	///
	/// This is the only bypass, it is per-file, and the expectation is *not* cleared: downloading the
	/// same app again is checked again from scratch.
	func importAnyway(_ dl: Download, failures: [DownloadIntegrity.Failure]) {
		guard let url = dl.retainedPackageURL ?? dl.pendingFileURL else {
			SigningLog.shared.error(
				.localized("Nothing left to import for %@ — the rejected file is gone.", arguments: dl.fileName),
				category: "download"
			)
			return
		}

		SigningLog.shared.warn(
			.localized("Importing %@ anyway, at the user's request, despite: %@", arguments: dl.fileName, DownloadIntegrity.describe(failures, fileName: dl.fileName)),
			category: "download"
		)
		dl.retainedPackageURL = nil

		// The row was removed when the check failed. Put it back: the import is about to happen, the
		// user should see it, and `finishImport` needs something to finish.
		if !downloads.contains(where: { $0.id == dl.id }) {
			downloads.append(dl)
			objectWillChange.send()
		}

		beginPackageImport(url: url, dl: dl)
	}

	/// Deletes a file that failed its check. Unconditional, unlike `CleanupManager`: a file the user
	/// just refused must not survive because a cleanup preference is off.
	private func discardRejectedPackage(at url: URL, fileName: String) {
		do {
			try FileManager.default.removeItem(at: url)
			SigningLog.shared.info(
				.localized("Discarded %@ — it did not match what the source published.", arguments: fileName),
				category: "download"
			)
		} catch {
			SigningLog.shared.error(
				.localized("Could not delete the rejected download %@: %@", arguments: fileName, error.localizedDescription),
				category: "download"
			)
		}
	}

	/// The import path itself: hash for the Logs tab, then hand the file to the importer.
	private func beginPackageImport(url: URL, dl: Download) {
		// Integrity audit: record the SHA-256 of every downloaded package in the Logs
		// tab, so it can be compared later against a hash the source published.
		let label = dl.fileName
		DispatchQueue.global(qos: .utility).async {
			if let hash = FileIntegrity.sha256(of: url) {
				SigningLog.shared.info(.localized("SHA-256 of %@: %@", arguments: label, hash), category: "download")
			}
		}

		DispatchQueue.main.async {
			self.objectWillChange.send()
			dl.progress = 1.0
			// Retry point if the import dies before it finishes.
			dl.pendingFileURL = url
			self.beginImport(for: dl)
		}

		FR.handlePackageFile(url, download: dl) { result in
			switch result {
			case .failure(let error):
				UINotificationFeedbackGenerator().notificationOccurred(.error)

				if self.isAppInBackground {
					self.sendCompletionNotification(for: dl, status: "❌ Import failed: \(error.localizedDescription)")
				} else {
					self.errorDelegate?.showUIErrorMessage(
						title: "Import Failed",
						message: error.localizedDescription
					)
				}

				DispatchQueue.main.async { self.finishImport(of: dl, succeeded: false) }
			case .success(let app):
				DispatchQueue.main.async {
					self.objectWillChange.send()
					dl.unpackageProgress = 1.0
					self.autoSignOrFinish(app, for: dl)
				}
			}
		}
	}

	private func autoSignOrFinish(_ app: AppInfoPresentable, for download: Download) {
		guard AutoSignManager.isEnabled else {
			if isAppInBackground { sendCompletionNotification(for: download, status: "✅ Added to Library") }
			finishImport(of: download, succeeded: true)
			return
		}

		endImport(for: download)
		objectWillChange.send()
		download.isSigning = true

		Task { @MainActor in
			switch await AutoSignManager.shared.sign(app) {
			case .success:
				self.report(for: download, status: "✅ Signed") {
					Toast.success(.localized("Signed successfully"), systemImage: "checkmark.seal.fill")
				}
			case .failure(let error):
				// Keep the import so it can still be signed by hand.
				self.report(for: download, status: "❌ Signing failed") {
					Toast.error(error.localizedDescription, duration: .sticky)
				}
			}

			self.objectWillChange.send()
			download.isSigning = false
			self.finishImport(of: download, succeeded: true)
		}
	}

	private func report(for download: Download, status: String, toast: () -> Void) {
		if isAppInBackground {
			sendCompletionNotification(for: download, status: status)
		} else {
			toast()
		}
	}

	private func finishImport(of download: Download, succeeded: Bool) {
		// Captured before `endImport()` clears it — the staged IPA is deleted below.
		let stagedURL = download.pendingFileURL

		download.isActive = false
		endImport(for: download)

		if succeeded {
			// Auto cleanup → "Delete Downloaded IPA": the archive already became a library app.
			Task { @MainActor in
				CleanupManager.shared.purgeDownloadArtifacts(fileURL: stagedURL, stageURL: nil)
			}
		}

		// Drop from activity tracking only once archiving completes (not on download finish).
		if succeeded {
			completedDownloadNames.append(download.fileName)
			allActivityDownloads.removeValue(forKey: download.id)
			finishedDownloadingIDs.remove(download.id)
		}

		// Snapshot before removing this one.
		let isLastDownload = !downloads.contains { other in
			other.id != download.id &&
			(other.isActive || other.isSigning || (other.progress > 0 && other.progress < 1.0) || (other.unpackageProgress > 0 && other.unpackageProgress < 1.0))
		}

		if let index = getDownloadIndex(by: download.id) {
			downloads.remove(at: index)
		}

		guard isLastDownload else { return }

		// Background archiving needs no completion state; foreground keeps it until reopened.
		if isAppInBackground {
			dismissLiveActivityImmediately()
		} else {
			endLiveActivity()
		}
	}
}

// MARK: - ErrorDelegate default

extension DownloadManager.ErrorDelegate {
	/// A conformer that only knows the plain message still compiles: the override is then
	/// unavailable and `onDismiss` runs, so the rejected file is deleted rather than imported
	/// without anyone deciding to.
	func showUIErrorMessage(
		title: String,
		message: String,
		actionTitle: String,
		action: @escaping () -> Void,
		dismissTitle: String,
		onDismiss: (() -> Void)?
	) {
		showUIErrorMessage(title: title, message: message)
		onDismiss?()
	}
}
