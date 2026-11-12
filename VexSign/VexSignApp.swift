//
//  VexSignApp.swift / AppDelegate
//  VexSign
//
//  Created by VexSign TeamSign Team on 10.04.2025.
//

import SwiftUI
import NimbleViews
import Nuke
import IDeviceSwift
import BackgroundTasks
import OSLog
import NimbleExtensions

@main
struct VexSignApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    let heartbeat = HeartbeatManager.shared

    @StateObject var downloadManager = DownloadManager.shared
    @StateObject private var tabSelection = TabSelectionObserver.shared
    @StateObject private var selfUpdate = SelfUpdateManager.shared
    @StateObject private var appLock = AppLockManager.shared
    /// Single observable source of truth for theme/font/animation preferences,
    /// injected into the environment so every view updates on change.
    @StateObject private var appearance = AppearanceStore.shared
    @AppStorage("VexSign.userTintColor") private var customWorkspaceAccent: String?
    @AppStorage("VexSign.onboardingCompleted") private var _onboardingCompleted = false
    @State private var _showOnboarding = false
    let storage = Storage.shared

    private var activeManualDownloads: [Download] {
        downloadManager.manualDownloads.filter { 
            $0.isActive || $0.progress > 0 || $0.unpackageProgress > 0 
        }
    }
    
    private var activeNonManualDownloads: [Download] {
        downloadManager.nonManualDownloads.filter { 
            $0.isActive || $0.progress > 0 || $0.unpackageProgress > 0 
        }
    }
    
    private var hasActiveDownloads: Bool {
        !activeManualDownloads.isEmpty || !activeNonManualDownloads.isEmpty
    }
    
    init() {
		// Migrate old UserDefaults keys (Feather/Ryuk) to new VexSign keys to preserve features for existing users
		Self._migrateLegacyUserDefaults()

		UserDefaults.standard.register(defaults: [
            "VexSign.serverMethod": 0, // Fully Local signing
            "VexSign.backgroundDownloadHeaderStartState": "collapsed",
            "VexSign.showDownloadHeaderInSourcesTab": true,
            "VexSign.downloadDisplayMode": "floating", // Default to floating icon
			"VexSign.sourcesShowUpdatesAsTab": true,
            "VexSign.downloadOverlayTheme": "darkGrey",
            "VexSign.dynamicOverlaySize": true,
            // Master cleanup switch: on, with every sub-toggle off, so updating the app
            // never changes what gets deleted. See Settings → Auto Cleanup.
            CleanupManager.Key.enabled: true
        ])

        // Enable liquid glass on iOS 19+
        if #available(iOS 19.0, *) {
            UserDefaults.standard.set(true, forKey: "com.apple.SwiftUI.IgnoreSolariumLinkedOnCheck")
        }
    }

	private static func _migrateLegacyUserDefaults() {
		let oldToNew: [String: String] = [
			"feather.selectedCert": "vexsign.selectedCert",
			"Feather.serverMethod": "VexSign.serverMethod",
			"Feather.backgroundDownloadHeaderStartState": "VexSign.backgroundDownloadHeaderStartState",
			"Feather.showDownloadHeaderInSourcesTab": "VexSign.showDownloadHeaderInSourcesTab",
			"Feather.downloadDisplayMode": "VexSign.downloadDisplayMode",
			"Feather.sourcesShowUpdatesAsTab": "VexSign.sourcesShowUpdatesAsTab",
			"Feather.downloadOverlayTheme": "VexSign.downloadOverlayTheme",
			"Feather.dynamicOverlaySize": "VexSign.dynamicOverlaySize",
			"Feather.userInterfaceStyle": "VexSign.userInterfaceStyle",
			"RyukSign.onboardingCompleted": "VexSign.onboardingCompleted"
		]
		for (oldKey, newKey) in oldToNew {
			if UserDefaults.standard.object(forKey: newKey) == nil,
			   let oldValue = UserDefaults.standard.object(forKey: oldKey) {
				UserDefaults.standard.set(oldValue, forKey: newKey)
			}
		}
	}
    
    var body: some Scene {
        WindowGroup {
            Group {
                let downloadDisplayMode = UserDefaults.standard.string(forKey: "VexSign.downloadDisplayMode") ?? "floating"

                if downloadDisplayMode == "header" {
                    VStack(spacing: 0) {
                        // Single animation point for header presence
                        if !activeManualDownloads.isEmpty || !activeNonManualDownloads.isEmpty {
                            downloadHeaderContent
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .zIndex(1)
                        }

                        VariedTabbarView()
                            .environment(\.managedObjectContext, storage.context)
                            .environmentObject(tabSelection)
                            .onOpenURL(perform: _handleURL)
                            .zIndex(0)
                    }
                    .animation(
                        appearance.animationsEnabled ? .spring(response: 0.4, dampingFraction: 0.8) : nil,
                        value: hasActiveDownloads
                    )
                } else {
                    ZStack {
                        VariedTabbarView()
                            .environment(\.managedObjectContext, storage.context)
                            .environmentObject(tabSelection)
                            .onOpenURL(perform: _handleURL)
                            .zIndex(0)

                        // Floating download bubble and overlay (always present to handle its own animations)
                        DownloadBubbleOverlayContainer(downloadManager: downloadManager)
                            .zIndex(1)
                    }
                }
            }
            .environmentObject(appearance)
            .modifier(VexWorkspaceTypography())
            .modifier(VexWorkspaceAccessibility())
            .tint(Theme.tint)
            .environment(\.nbWorkspaceBackground, Theme.background)
            .environment(\.nbWorkspaceCard, Theme.card)
            .preferredColorScheme(appearance.visualTheme.preferredColorScheme)
            .buttonStyle(VexSignFlareButtonStyle(enabled: appearance.animationsEnabled))
            .vexSignWebMotion()
            .overlay(alignment: .bottom) {
                InstallQueuePill()
            }
            .overlay {
                // App Lock: covers everything, including the download bubble, while locked.
                if appLock.isLocked {
                    AppLockScreenView()
                        .transition(.opacity)
                        .zIndex(99)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: appLock.isLocked)
            .onReceive(NotificationCenter.default.publisher(for: .heartbeatInvalidHost)) { _ in
                DispatchQueue.main.async {
                    UIAlertController.showAlertWithOk(
                        title: "InvalidHostID",
                        message: .localized("Your pairing file is invalid and is incompatible with your device, please import a valid pairing file.")
                    )
                }
            }
            .onAppear {
                if let style = UIUserInterfaceStyle(rawValue: UserDefaults.standard.integer(forKey: "VexSign.userInterfaceStyle")) {
                    UIApplication.topViewController()?.view.window?.overrideUserInterfaceStyle = style
                }

                UIApplication.topViewController()?.view.window?.tintColor = UIColor(Theme.tint)
            }
            .nbOnChange(of: customWorkspaceAccent) { _ in
                UIApplication.topViewController()?.view.window?.tintColor = UIColor(Theme.tint)
            }
            .nbOnChange(of: appearance.visualTheme) { _ in
                UIApplication.topViewController()?.view.window?.tintColor = UIColor(Theme.tint)
            }
            .nbOnChange(of: scenePhase) { newPhase in
                if newPhase == .background {
                    EcosystemMaintenance.schedule()
                    appLock.lockIfNeeded()
                }
                if newPhase == .active {
                    Task { @MainActor in
                        SourcesViewModel.shared.resetLoadingState()
                        LibraryStatusStore.shared.refreshKnown()
                        InstallQueue.shared.reconcileOnForeground()
                    }
                    appLock.authenticateIfNeeded()
                }
            }
            .task {
                await selfUpdate.checkOnLaunch()
                await EcosystemMaintenance.run()
                await CertificateExpiryMonitor.checkOnLaunch()
                StorageRules.warnIfOverLimit()
                if !_onboardingCompleted {
                    _showOnboarding = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vexShowOnboarding)) { _ in
                _showOnboarding = true
            }
            .sheet(isPresented: $_showOnboarding) {
                // The wizard reads certificates/sources via @FetchRequest, so
                // it needs the managed object context in its own environment
                // (the sheet does not inherit the tab content's injection).
                OnboardingView()
                    .environment(\.managedObjectContext, storage.context)
            }
            .sheet(isPresented: $selfUpdate.presentUpdatePrompt) {
                if let release = selfUpdate.available {
                    SelfUpdateSheet(release: release)
                }
            }
        }
    }

    @ViewBuilder
    private var downloadHeaderContent: some View {
        if !activeManualDownloads.isEmpty {
            DownloadHeaderView(downloadManager: downloadManager)
        } else if !activeNonManualDownloads.isEmpty {
            let showInSourcesTab = UserDefaults.standard.bool(forKey: "VexSign.showDownloadHeaderInSourcesTab")
            let shouldHide = tabSelection.selectedTab == .appStore && !showInSourcesTab

            if !shouldHide {
                ConditionalDownloadHeaderView(downloads: activeNonManualDownloads)
            }
        }
    }
	
	private func _handleURL(_ url: URL) {
		let scheme = url.scheme?.lowercased()
		// Support both new vexsign:// and legacy feather:// for backward compatibility - don't break features
		if scheme == "vexsign" || scheme == "feather" {
			/// vexsign://import-certificate?p12=<base64>&mobileprovision=<base64>&password=<base64>
			if url.host == "import-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
					let queryItems = components.queryItems
				else {
					return
				}
				
				func queryValue(_ name: String) -> String? {
					queryItems.first(where: { $0.name == name })?.value?.removingPercentEncoding
				}
				
				guard
					let p12Base64 = queryValue("p12"),
					let provisionBase64 = queryValue("mobileprovision"),
					let passwordBase64 = queryValue("password"),
					let passwordData = Data(base64Encoded: passwordBase64),
					let password = String(data: passwordData, encoding: .utf8)
				else {
					return
				}
				
				let generator = UINotificationFeedbackGenerator()
				generator.prepare()
				
				guard
					let p12URL = FileManager.default.decodeAndWrite(base64: p12Base64, pathComponent: ".p12"),
					let provisionURL = FileManager.default.decodeAndWrite(base64: provisionBase64, pathComponent: ".mobileprovision"),
					FR.checkPasswordForCertificate(for: p12URL, with: password, using: provisionURL)
				else {
					generator.notificationOccurred(.error)
					UIAlertController.showAlertWithOk(
						title: .localized("Import Failed"),
						message: .localized("Failed to import certificate. Please check that the certificate and password are valid.")
					)
					return
				}
				
				FR.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: password
				) { error in
					if let error = error {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					} else {
						generator.notificationOccurred(.success)
					}
				}
				
				return
			}
			/// vexsign://export-certificate?callback_template=<template>
			/// ?callback_template=: This is how we callback to the application requesting the certificate, this will be a url scheme
			/// 	example: livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29
			/// 	decoded: livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)
			/// $(BASE64_CERT) and $(PASSWORD) must be presenting in the callback template so we can replace them with the proper content
			if url.host == "export-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				else {
					return
				}
				
				let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
				guard let callbackTemplate = queryItems["callback_template"]?.removingPercentEncoding else { return }
				
				let lowercased = callbackTemplate.lowercased()
				guard !lowercased.hasPrefix("http://") && !lowercased.hasPrefix("https://") &&
					  !lowercased.hasPrefix("file://") && !lowercased.hasPrefix("javascript:") else {
					return
				}

				FR.exportCertificateAndOpenUrl(using: callbackTemplate)
			}
			/// vexsign://tweak-repository/<url> or vexsign://tweak-repository?url=<url>
			if url.host == "tweak-repository" || url.path.hasPrefix("/tweak-repository") {
				let queryURL = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
					.first(where: { $0.name.lowercased() == "url" })?.value
				let raw = queryURL ?? url.validatedScheme(after: "/tweak-repository/")
				if let raw, let repositoryURL = URL(string: raw), repositoryURL.scheme?.lowercased() == "https" {
					Task {
						do {
							let count = try await TweakManager.shared.addRepository(repositoryURL)
							Toast.success(String.localized("Imported %lld tweaks", arguments: count), systemImage: "wrench.and.screwdriver.fill")
						} catch {
							Toast.error(error.localizedDescription, duration: .sticky)
						}
					}
				}
				return
			}
			/// vexsign://repo-app?id=<currentUniqueId>&name=<name>&source=<repository>
			/// Emitted by the Repository Apps widget: opens that app in the App Store tab,
			/// which is the same navigation a search result performs.
			if url.host == "repo-app" {
				let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
				func queryValue(_ name: String) -> String? {
					queryItems.first(where: { $0.name == name })?.value
				}

				if let appID = queryValue("id"), !appID.isEmpty {
					AppNavigationManager.shared.forceNavigateToApp(
						appId: appID,
						appName: queryValue("name") ?? .localized("App"),
						sourceIdentifier: queryValue("source")
					)
				}
				return
			}
			/// vexsign://library · vexsign://downloads · vexsign://appStore …
			/// The Live Activities already emitted these; this is what receives them.
            if let route = WorkspaceRoute.resolve(host: url.host ?? "") {
                TabSelectionObserver.shared.navigate(to: route)
                return
            }
			/// vexsign://source/<url>
			if let fullPath = url.validatedScheme(after: "/source/") {
				FR.handleSource(fullPath) { _ in }
			}
			/// vexsign://direct-install?url=<url>&sign=<true|false> or vexsign://direct-install/<url>
			if url.host == "direct-install" || url.path.hasPrefix("/direct-install") {
				var targetURLString: String?

				if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
					if let urlParam = components.queryItems?.first(where: { $0.name.lowercased() == "url" })?.value {
						targetURLString = urlParam
					}
				}

				if targetURLString == nil {
					targetURLString = url.validatedScheme(after: "/direct-install/")
				}

				if let targetURLString, let downloadURL = URL(string: targetURLString) {
					_ = DownloadManager.shared.startDownload(from: downloadURL)
					Toast.info(.localized("Direct download started"), systemImage: "arrow.down.app")
				}
				return
			}
			/// vexsign://install/<url.ipa>
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath) {
				_ = DownloadManager.shared.startDownload(from: downloadURL)
			}
		} else {
			let ext = url.pathExtension.lowercased()
			if ext == "ipa" || ext == "tipa" {
let workLease: AppOperationRegistry.Lease
                do { workLease = try await AppOperationRegistry.shared.acquireTemporaryWork() }
                error {
                    Toast.error(error.localizedDescription, duration: .long)
                    return
                }
				// Handle file import using NSFileCoordinator for proper access control
				let tempDir = FileManager.default.uniqueTemporaryDirectory("VexSignShared")
				let destinationURL = tempDir.appendingPathComponent(url.lastPathComponent)

				let didStartAccessing = url.startAccessingSecurityScopedResource()

				let coordinator = NSFileCoordinator()
				var coordinatorError: NSError?

				var copyError: Error?
				coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { sourceURL in
					do {
						try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
						try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
					} catch {
						copyError = error
					}
				}

				if didStartAccessing {
					url.stopAccessingSecurityScopedResource()
				}

				// Surface the real reason the staged copy failed, if any.
				if let error = copyError {
					UIAlertController.showErrorWithCopy(
						title: .localized("Import Failed"),
						message: "Could not copy the shared file into the app.\n\nFile: \(url.lastPathComponent)\nReason: \(error.localizedDescription)"
					)
					return
				}

				if let error = coordinatorError {
					UIAlertController.showErrorWithCopy(
						title: .localized("Import Failed"),
						message: "Could not read the shared file. The other app may have denied access.\n\nFile: \(url.lastPathComponent)\nReason: \(error.localizedDescription)"
					)
					return
				}

				guard FileManager.default.fileExists(atPath: destinationURL.path) else {
					UIAlertController.showErrorWithCopy(
						title: .localized("Import Failed"),
						message: "The shared file could not be copied into the app. It may be inaccessible, or storage may be full.\n\nFile: \(url.lastPathComponent)"
					)
					return
				}

				// Manual download to show progress in the header; completion reports the real outcome.
				let id = "VexSignManualDownload_\(UUID().uuidString)"
				_ = DownloadManager.shared.startArchive(from: destinationURL, id: id) { error in
                    defer { withExtendedLifetime(workLease) {} }
					if error is CancellationError { return }
                    if let error = error {
						UIAlertController.showErrorWithCopy(
							title: .localized("Import Failed"),
							message: error.localizedDescription
						)
					} else {
						Toast.success(.localized("Imported successfully"), systemImage: "square.and.arrow.down.fill")
					}
				}

				return
			}

			// Tweak files shared into the app (Open in / share sheet / AirDrop) → Tweak Manager.
			let tweakExtensions: Set<String> = ["dylib", "deb", "framework", "bundle", "zip"]
			if tweakExtensions.contains(ext) {
				_importSharedTweak(url)
				return
			}
		}
	}

	/// Imports a tweak file shared into the app. Archives are unpacked and scanned for
	/// injectables; everything else is added directly. Cleans up its temp copy afterwards.
	private func _importSharedTweak(_ url: URL) {
		let ext = url.pathExtension.lowercased()
		let tempDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("VexSignSharedTweak_\(UUID().uuidString)", isDirectory: true)
		let destinationURL = tempDir.appendingPathComponent(url.lastPathComponent)

		let didStartAccessing = url.startAccessingSecurityScopedResource()
		let coordinator = NSFileCoordinator()
		var coordinatorError: NSError?
		coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { sourceURL in
			do {
				try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
				try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
			} catch {
				DispatchQueue.main.async { Toast.error(.localized("Import Failed"), duration: .long) }
			}
		}
		if didStartAccessing { url.stopAccessingSecurityScopedResource() }

		guard coordinatorError == nil, FileManager.default.fileExists(atPath: destinationURL.path) else {
			Toast.error(.localized("Import Failed"), duration: .long)
			return
		}

		if ext == "zip" {
			Task {
				do {
					let result = try await TweakExtractor.extract(fromZip: destinationURL)
					await MainActor.run {
						// Ignore artifacts inside a packaged app (a zipped .app/Payload).
						let injectables = result.candidates.filter { !$0.url.path.contains(".app/") }
						var added = 0
						for candidate in injectables {
							if TweakManager.shared.addTweak(
								name: candidate.url.deletingPathExtension().lastPathComponent,
								from: candidate.url
							) != nil { added += 1 }
						}
						try? FileManager.default.removeItem(at: result.workDir)
						try? FileManager.default.removeItem(at: tempDir)
						if added > 0 {
							Toast.success(String.localized("Added %lld tweaks", arguments: added), systemImage: "wrench.and.screwdriver.fill")
						} else {
							Toast.error(.localized("No tweaks found in the archive"), duration: .long)
						}
					}
				} catch {
					await MainActor.run {
						try? FileManager.default.removeItem(at: tempDir)
						Toast.error(error.localizedDescription, duration: .long)
					}
				}
			}
		} else {
			if TweakManager.shared.addTweak(
				name: destinationURL.deletingPathExtension().lastPathComponent,
				from: destinationURL
			) != nil {
				Toast.success(.localized("Added to Tweak Manager"), systemImage: "wrench.and.screwdriver.fill")
			} else {
				Toast.error(.localized("Couldn't import tweak"), duration: .sticky)
			}
			try? FileManager.default.removeItem(at: tempDir)
		}
	}
}

class AppDelegate: NSObject, UIApplicationDelegate, DownloadManager.ErrorDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		// Create the store here, on the main thread, before anything else can
		// reach for it: the certificate importer starts from a utility queue a
		// few lines down, and whoever touches `Storage.shared` first is the
		// thread that creates the container.
		_ = Storage.shared

		_createPipeline()
		_createDocumentsDirectories()
		StorageManager.purgeStaleTemporary()
        Storage.shared.recoverPendingAppDeletions()
		InstallCleanup.flushOnLaunch()
		_addDefaultCertificates()
		_registerBackgroundTasks()
        EcosystemMaintenance.register()
        EcosystemMaintenance.schedule()
		scheduleAutomationMaintenance()

		// Apple Watch companion: a no-op unless the user switched it on.
		CompanionBridge.shared.activateIfNeeded()

		// Idempotent, no-op after first run.
		VexSignAPI.migrateIfNeeded()

		// Attach the premium repository API key to every manifest fetch/decrypt request.
		FR.registerRepositoryKeyProvider()

		DownloadManager.shared.errorDelegate = self

		return true
	}
	
	// MARK: - DownloadManager.ErrorDelegate
	
	func showUIErrorMessage(title: String, message: String) {
		DispatchQueue.main.async {
			UIAlertController.showErrorWithCopy(
				title: .localized(title),
				message: message
			)
		}
	}

	/// a download that failed its integrity check needs an answer, not an acknowledgement —
	/// the file is either imported deliberately or deleted.
	func showUIErrorMessage(
		title: String,
		message: String,
		actionTitle: String,
		action: @escaping () -> Void,
		dismissTitle: String,
		onDismiss: (() -> Void)?
	) {
		DispatchQueue.main.async {
			UIAlertController.showAlertWithOptions(
				title: .localized(title),
				message: message,
				actions: [
					(actionTitle, .default, action),
					(dismissTitle, .cancel, onDismiss)
				]
			)
		}
	}

	func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
	
	private func _addDefaultCertificates() {
		CertificateAutoImporter.shared.importBundledCertificatesIfNeeded()
	}
	
	private func _createPipeline() {
		DataLoader.sharedUrlCache.diskCapacity = 0
		
		let pipeline = ImagePipeline {
			let dataLoader: DataLoader = {
				let config = URLSessionConfiguration.default
				config.urlCache = nil
				return DataLoader(configuration: config)
			}()
			let dataCache = try? DataCache(name: "com.vexsign.datacache") // disk cache
			let imageCache = Nuke.ImageCache() // memory cache
			dataCache?.sizeLimit = 500 * 1024 * 1024
			imageCache.costLimit = 100 * 1024 * 1024
			$0.dataCache = dataCache
			$0.imageCache = imageCache
			$0.dataLoader = dataLoader
			$0.dataCachePolicy = .automatic
			$0.isStoringPreviewsInMemoryCache = false
		}
		
		ImagePipeline.shared = pipeline
	}
	
	private func _createDocumentsDirectories() {
		let fileManager = FileManager.default

		let directories: [URL] = [
			fileManager.archives,
			fileManager.certificates,
			fileManager.signed,
			fileManager.unsigned
		]
		
		for url in directories {
			try? fileManager.createDirectoryIfNeeded(at: url)
		}
	}
}
