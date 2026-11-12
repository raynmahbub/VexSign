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
    @Published var interruptedDownloads: [DownloadRecoveryJournal.Record] = []
    @Published var recoveryWarning: String?
    var recoveryJournal: DownloadRecoveryJournal?
    var integrityDecisions: [ObjectIdentifier: Download] = [:]
	@Published var currentDownloadSpeed: Int64 = 0

	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}

	var activeNetworkDownloads: [Download] {
		downloads.filter { !$0.onlyArchiving && $0.isActive && !$0.isWaitingForSlot && !$0.isVerifying && !$0.isImporting && !$0.isSigning && !$0.isPaused && $0.task?.state == .running }
	}

	/// Unpacking or auto signing. Both hold the keep-alive open.
	var processingDownloads: [Download] {
		downloads.filter { $0.isVerifying || $0.isImporting || $0.isSigning }
	}

	var hasUnfinishedWork: Bool {
		downloads.contains { $0.isActive || $0.isWaitingForSlot || $0.isVerifying || $0.isImporting || $0.isSigning || ($0.progress > 0 && $0.progress < 1.0) }
	}

	var _backgroundSession: URLSession?
	var _foregroundSession: URLSession?
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
    private var isBatchControllingDownloads = false
    private let configureSystemServices: Bool

	var completedDownloadNames: [String] = []
	var isActivityShowingCompletion = false

	// Every download in this Live Activity session, incl. ones downloaded but not yet archived.
	var allActivityDownloads: [String: (fileName: String, downloaded: Int64, total: Int64)] = [:]

	// Downloads that finished downloading (X in the X/Y counter) — distinct from archiving completion.
	var finishedDownloadingIDs: Set<String> = []

    override convenience init() {
        self.init(configureServices: true)
    }

    /// Tests can supply isolated sessions without registering notifications or background work.
    init(configureServices: Bool) {
        self.configureSystemServices = configureServices
        super.init()
        guard configureServices else { return }
        let journal = DownloadRecoveryJournal(root: DownloadRecoveryJournal.directory)
        recoveryJournal = journal
        do { interruptedDownloads = try journal.load() }
        catch { recoveryWarning = error.localizedDescription }

		let foregroundConfig = URLSessionConfiguration.default
		foregroundConfig.timeoutIntervalForRequest = 300 // 5 min
		foregroundConfig.timeoutIntervalForResource = 7200 // 2 hours
		foregroundConfig.allowsExpensiveNetworkAccess = true
		foregroundConfig.allowsConstrainedNetworkAccess = true
		foregroundConfig.httpMaximumConnectionsPerHost = 10
		foregroundConfig.multipathServiceType = .handover
		foregroundConfig.waitsForConnectivity = false

		_foregroundSession = URLSession(configuration: foregroundConfig, delegate: self, delegateQueue: .main)

		let backgroundConfig: URLSessionConfiguration = URLSessionConfiguration.background(withIdentifier: "com.vexsign.app.background")
		backgroundConfig.isDiscretionary = false // don't wait for ideal conditions
		backgroundConfig.sessionSendsLaunchEvents = true
		backgroundConfig.timeoutIntervalForRequest = 300 // 5 min
		backgroundConfig.timeoutIntervalForResource = 7200 // 2 hours
		backgroundConfig.allowsExpensiveNetworkAccess = true
		backgroundConfig.allowsConstrainedNetworkAccess = true
		backgroundConfig.httpMaximumConnectionsPerHost = 10
		backgroundConfig.waitsForConnectivity = false
		backgroundConfig.networkServiceType = .responsiveData

		_backgroundSession = URLSession(configuration: backgroundConfig, delegate: self, delegateQueue: .main)
        // No silent replay: unowned restored transfers require explicit recovery review.
        _backgroundSession?.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in tasks where !self.downloads.contains(where: { $0.task === task }) { task.cancel() }
            }
        }

        // Monitor initialization is deliberate even before the first Wi-Fi-only download.
        _ = DownloadPreferences.isOnExpensivePath
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [DownloadPreferences.pathChanged, UIDevice.batteryStateDidChangeNotification,
                     UserDefaults.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(networkPolicyDidChange), name: name, object: nil)
        }

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
        reconcileNetworkPolicy()
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

        // Foregrounding is not consent to undo an explicit user pause.
        drainNetworkQueue()

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
			if let task = download.task, (task.state == .running || task.state == .suspended) {
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
        drainNetworkQueue()
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
        guard let data = download.resumeData, let recoveryJournal else { return }
        do { try recoveryJournal.saveResumeData(data, id: download.recoveryID, source: download.url) }
        catch {
            DispatchQueue.main.async { self.recoveryWarning = error.localizedDescription }
        }
    }

    private func loadResumeData(for download: Download) -> Data? {
        do { return try recoveryJournal?.resumeData(id: download.recoveryID, source: download.url) }
        catch { recoveryWarning = error.localizedDescription; return nil }
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
        guard let request = DownloadNotificationBuilder.progress(forActiveDownloads: activeDownloads) else {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["merged_download_progress"])
            return
        }
        UNUserNotificationCenter.current().add(request)
	}

	func sendSystemNotification(title: String, body: String, identifier: String) {
        UNUserNotificationCenter.current().add(
            DownloadNotificationBuilder.system(title: title, body: body, identifier: identifier)
        )
	}

	func sendCompletionNotification(for download: Download, status: String) {
        UNUserNotificationCenter.current().add(DownloadNotificationBuilder.completion(for: download, status: status))
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
	
	// MARK: - Public Methods
	
	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		appName: String? = nil,
		appDescription: String? = nil,
		integrity: DownloadIntegrity.Expectation? = nil,
        recoveryID: UUID = UUID(),
        recoveredResumeData: Data? = nil
	) -> Download {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                self.startDownload(from: url, id: id, appName: appName, appDescription: appDescription, integrity: integrity, recoveryID: recoveryID, recoveredResumeData: recoveredResumeData)
            }
        }
		if DownloadIntegrity.expectationExceedsPackageLimit(integrity) {
			Task { @MainActor in Toast.error(PackageDownloadURLPolicy.Failure.packageTooLarge.localizedDescription, duration: .long) }
			return Download(id: id, url: url, appName: appName, appDescription: appDescription, integrity: integrity)
		}
		do {
			try PackageDownloadURLPolicy.validateInitialURL(url)
		} catch {
			Task { @MainActor in Toast.error(error.localizedDescription, duration: .long) }
			return Download(id: id, url: url, appName: appName, appDescription: appDescription, integrity: integrity)
		}
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

        if let existingDownload = downloads.first(where: { $0.url == url }) {
            // Same URL: keep the row, but take the promise this call was given (a later source
            // fetch may know a size the first one did not).
            if let integrity, !existingDownload.isVerifying, !existingDownload.isImporting, !existingDownload.isSigning {
                existingDownload.integrity = integrity
            }
            resumeDownload(existingDownload)
            return existingDownload
        }

        let download = Download(id: id, url: url, appName: appName, appDescription: appDescription, integrity: integrity, recoveryID: recoveryID)
        download.isWaitingForSlot = true

		guard let session = isAppInBackground ? _backgroundSession : _foregroundSession else {
			download.isActive = false
			download.isWaitingForSlot = false
			let error = NSError(domain: "VexSign.Download", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download sessions not initialized"])
			DispatchQueue.main.async { self.errorDelegate?.showUIErrorMessage(title: "Download Failed", message: error.localizedDescription) }
			return download
		}

		var request = URLRequest(url: url)
		request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		request.networkServiceType = .responsiveData
		request.allowsExpensiveNetworkAccess = !DownloadPreferences.wifiOnly
		request.allowsConstrainedNetworkAccess = !DownloadPreferences.wifiOnly
		request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")

		// Auth headers for premium sources.
		VexSignAPI.applyAuthHeaders(to: &request)

        let task: URLSessionDownloadTask
        if let recoveredResumeData { task = session.downloadTask(withResumeData: recoveredResumeData) }
        else { task = session.downloadTask(with: request) }
		download.task = task
		task.priority = 1.0
        // Register ownership before a task can deliver callbacks or a duplicate request arrives.
        ownImportRecovery(download)
        downloads.append(download)
        checkpointRecovery(download, stage: .downloading)
        drainNetworkQueue()
        if configureSystemServices {
            startProgressTimer()
            if isAppInBackground { ensureKeepAlive() }
            if #available(iOS 19.0, *), let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                appDelegate.submitContinuedProcessingTask()
            }
            startLiveActivityIfNeeded()
        }

		return download
	}
	
	func startArchive(from url: URL, id: String = UUID().uuidString, appName: String? = nil, reviewDuplicates: Bool = false, completion: ((Error?) -> Void)? = nil) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true, appName: appName)
        ownImportRecovery(download)
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
                    if error is CancellationError {
                        self.allActivityDownloads.removeValue(forKey: download.id)
                        self.finishedDownloadingIDs.remove(download.id)
                        self.finishImport(of: download, succeeded: false)
                        completion?(error)
                        return
                    }
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
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.resumeDownload(download) }
            return
        }
        if download.isImporting || download.isVerifying {
            download.importControl.resume()
            download.isPaused = false
            download.isActive = true
            objectWillChange.send()
            return
        }
        guard !download.isSigning, !download.onlyArchiving, download.progress < 1.0,
              downloads.contains(where: { $0 === download }) else { return }
        // A second request for the same active URL is a no-op, not a replacement task.
        guard download.task?.state != .running, !download.isWaitingForSlot else { return }
        guard networkPolicyAllowsStarting else { return }
        if DownloadIntegrity.expectationExceedsPackageLimit(download.integrity) {
            download.isActive = false
            download.isPaused = false
            DispatchQueue.main.async {
                Toast.error(PackageDownloadURLPolicy.Failure.packageTooLarge.localizedDescription, duration: .long)
            }
            return
        }
        do {
            try PackageDownloadURLPolicy.validateInitialURL(download.url)
        } catch {
            download.isActive = false
            download.isPaused = false
            DispatchQueue.main.async { Toast.error(error.localizedDescription, duration: .long) }
            return
        }
        if download.task?.state != .suspended {
            if download.resumeData == nil { download.resumeData = loadResumeData(for: download) }
            guard let session = isAppInBackground ? _backgroundSession : _foregroundSession else {
                download.isActive = false
                download.isWaitingForSlot = false
                download.isPaused = true
                return
            }
            if let resumeData = download.resumeData {
                download.task = session.downloadTask(withResumeData: resumeData)
                download.resumeData = nil
            } else {
                var request = URLRequest(url: download.url)
                request.allowsExpensiveNetworkAccess = !DownloadPreferences.wifiOnly
                request.allowsConstrainedNetworkAccess = !DownloadPreferences.wifiOnly
                VexSignAPI.applyAuthHeaders(to: &request)
                download.task = session.downloadTask(with: request)
            }
        }
        download.isPaused = false
        download.isWaitingForSlot = true
        download.isActive = false
        drainNetworkQueue()
        if configureSystemServices {
            startProgressTimer()
            if isAppInBackground { ensureKeepAlive() }
        }
    }

    private var networkPolicyAllowsStarting: Bool {
        !GameMode.isEnabled
            && (!DownloadPreferences.wifiOnly || !DownloadPreferences.isOnExpensivePath)
            && (!DownloadPreferences.chargeOnly || DownloadPreferences.isCharging)
    }

    @objc private func networkPolicyDidChange() {
        reconcileNetworkPolicy()
    }

    /// Policy-held tasks remain waiting, distinct from explicit user pauses.
    func reconcileNetworkPolicy(allowed: Bool? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.reconcileNetworkPolicy(allowed: allowed) }
            return
        }
        let canRun = allowed ?? networkPolicyAllowsStarting
        if !canRun {
            for download in downloads where !download.isImporting && !download.isVerifying && !download.isSigning && !download.onlyArchiving && download.progress < 1 {
                if download.task?.state == .running {
                    download.task?.suspend()
                    download.isActive = false
                    if !download.isPaused { download.isWaitingForSlot = true }
                }
            }
        } else { drainNetworkQueue() }
    }

    /// FIFO admission shared by new and resumed transfers. Waiting rows own suspended tasks.
    /// All admission and row registration is serialized on the main queue.
    func drainNetworkQueue() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.drainNetworkQueue() }
            return
        }
        guard !isBatchControllingDownloads, networkPolicyAllowsStarting else { return }
        let waiting = downloads.filter { $0.isWaitingForSlot && !$0.isPaused }
        let slots = max(0, DownloadPreferences.maxParallel - activeNetworkDownloads.count)
        for download in waiting.prefix(slots) {
            guard download.task?.state == .suspended else { continue }
            download.isWaitingForSlot = false
            download.isActive = true
            download.task?.resume()
        }
    }

    /// Release a network slot independently of the subsequent verification/import owner.
    func networkTransferFinished(_ download: Download, task: URLSessionTask) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.networkTransferFinished(download, task: task) }
            return
        }
        guard download.task === task else { return }
        download.isActive = false
        download.isWaitingForSlot = false
        drainNetworkQueue()
    }

    func pauseDownload(_ download: Download) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.pauseDownload(download) }
            return
        }
        if download.isImporting || download.isVerifying {
            guard download.importControl.pause() else { return }
            download.isPaused = true
            objectWillChange.send()
            return
        }
        guard !download.isSigning, !download.onlyArchiving else { return }
        if download.task?.state == .running { download.task?.suspend() }
        download.isWaitingForSlot = false
        download.isPaused = true
        download.isActive = false
        drainNetworkQueue()
    }

    func cancelDownload(_ download: Download) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.cancelDownload(download) }
            return
        }
        if integrityDecisions.removeValue(forKey: ObjectIdentifier(download)) != nil {
            download.packageVerification.cancel()
            download.importControl.cancel()
            if let url = download.retainedPackageURL {
                download.retainedPackageURL = nil
                finishCancelledVerification(url: url, dl: download)
            }
            return
        }
        // Auto-sign is a separate owner; do not hide a still-running signer.
        guard !download.isSigning else { return }
        if download.isImporting || download.isVerifying {
            guard download.importControl.cancel() else { return }
            download.packageVerification.cancel()
            download.isPaused = false
            // Keep the row until the worker has stopped and cleaned its files.
            objectWillChange.send()
            return
        }
        download.importControl.cancel()
        download.packageVerification.cancel()
        clearRecovery(download)
		download.task?.cancel()
        download.isWaitingForSlot = false
		download.isActive = false


		DispatchQueue.main.async {
			if let index = self.downloads.firstIndex(where: { $0 === download }) {
				self.objectWillChange.send()

				// Drop from tracking so a manually stopped download leaves overall progress.
				self.allActivityDownloads.removeValue(forKey: download.id)
				self.finishedDownloadingIDs.remove(download.id)

				self.downloads.remove(at: index)
                self.drainNetworkQueue()

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
    /// Network jobs leave immediately. Imports leave only after cooperative cancellation
    /// and workspace cleanup; an auto-sign run is not hidden or cancelled by this action.
	func cancelAllDownloads() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.cancelAllDownloads() }
            return
        }
        isBatchControllingDownloads = true
        defer { isBatchControllingDownloads = false }
		let currentDownloads = downloads.filter { $0.isActive || $0.isWaitingForSlot || $0.isPaused || $0.isVerifying || $0.isImporting || $0.isSigning } + Array(integrityDecisions.values)
		for download in currentDownloads {
			cancelDownload(download)
		}
	}

	func pauseAllDownloads() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.pauseAllDownloads() }
            return
        }
        isBatchControllingDownloads = true
        defer { isBatchControllingDownloads = false }
		let currentDownloads = downloads.filter {
			$0.isActive || $0.isWaitingForSlot || ($0.progress > 0 && $0.progress < 1.0) || $0.isVerifying || $0.isImporting || $0.isSigning
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
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.resumeAllDownloads() }
            return
        }
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
