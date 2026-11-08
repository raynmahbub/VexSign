//
//  AppInstaller.swift
//  VexSign
//
//  Created by VexSign Team
//

import Combine
import Foundation
import SwiftUI
import IDeviceSwift
import OSLog
import NimbleExtensions

/// Install pipeline without a UI, so the single-app card and the batch queue can share it.
@MainActor
final class AppInstaller: ObservableObject {
	enum Outcome {
		/// The device reports the app, at the version that was sent.
		case installed
		/// The device reports the app, at another version: installed, but not what was sent.
		case installedOtherVersion(String?)
		case cancelled
		case exported(URL?)
		/// Copied to the host inbox; import/signing/launch are still pending.
		case guestImportPrepared
	}

	let app: AppInfoPresentable
	let viewModel: InstallerStatusViewModel

	/// redirect page fallback.
	@Published var isPresentingFallbackPage = false
    @Published private(set) var installationPhase: InstallConfirmation.Phase = .waitingForStart
    private var _hasServedPayload = false


	private let _isSharing: Bool
	private let _installationMethod = UserDefaults.standard.integer(forKey: "VexSign.installationMethod")
	private let _serverMethod: Int
	private let _useShareSheet = UserDefaults.standard.bool(forKey: "VexSign.useShareSheetForArchiving")
	private let _useNovaDNSDynamic = UserDefaults.standard.bool(forKey: "VexSign.useNovaDNSDynamic")

    private var _preparedPackage: Task<PreparedInstallationPackage, Error>?
    private var _packageArchive: InstallationArchive?
    private(set) var hasPackaged = false
    var onPackaged: (() -> Void)?
    var onWorkflowStage: ((UnifiedTaskPhase) -> Void)?
    var onConfirmationReason: ((String) -> Void)?

    /// Settings changed while prewarming? Discard the snapshot and build afresh.
    var preparationMatchesSettings: Bool {
        _installationMethod == UserDefaults.standard.integer(forKey: "VexSign.installationMethod") &&
        _serverMethod == UserDefaults.standard.integer(forKey: "VexSign.serverMethod") &&
        _useNovaDNSDynamic == UserDefaults.standard.bool(forKey: "VexSign.useNovaDNSDynamic") &&
        _preparationCompression == ArchiveHandler.getCompressionLevel() &&
        _preparationIPFix == UserDefaults.standard.bool(forKey: "VexSign.ipFix")
    }
    private let _preparationCompression = ArchiveHandler.getCompressionLevel()
    private let _preparationIPFix = UserDefaults.standard.bool(forKey: "VexSign.ipFix")

    /// Packaging only: never starts a server, opens an install URL or reports success.
    func prepareForQueuedOTA() {
        guard !_isSharing, _installationMethod == 0, !_hasFinished, _preparedPackage == nil else { return }
        _preparedPackage = Task { try await _createPackage() }
    }

	private var _server: ServerInstaller?
	private var _progressTask: Task<Void, Never>?
    private var _runTask: Task<Void, Never>?
    private var _fallbackTask: Task<Void, Never>?
    private var _confirmationTask: Task<Void, Never>?
	private var _statusObserver: AnyCancellable?
	private var _completion: ((Result<Outcome, Error>) -> Void)?
	private var _hasFinished = false
	private var _declineObserver: NSObjectProtocol?
	private var _declineCheck: DispatchWorkItem?
	/// One idevice retry per install, so a genuinely broken pair doesn't loop.
	private var _didAttemptIdeviceFallback = false
	/// The device-side evidence that turns "progress ended" into an answer.
    private var _installBaseline: InstallWatcher.Baseline?
	private let _probe: InstalledAppProbing
	private var _lastPPQRefresh = Date()

	var fallbackPageURL: URL? { _server?.pageEndpoint }

    var installationMethodCode: String {
        if _isSharing { return "export" }
        if _installationMethod == 2 { return "guest-import" }
        return _installationMethod == 1 || _didAttemptIdeviceFallback ? "paired-device" : "OTA"
    }

	var canRetryUsingLocalhost: Bool { !_isSharing && _installationMethod == 0 && _serverMethod == 0 }

	init(
		app: AppInfoPresentable,
		isSharing: Bool = false,
		useLocalhost: Bool = false,
		probe: InstalledAppProbing = InstalledAppProbe()
	) {
		self._probe = probe
		self._serverMethod = useLocalhost ? 1 : UserDefaults.standard.integer(forKey: "VexSign.serverMethod")
		self.app = app
		self._isSharing = isSharing
		self.viewModel = InstallerStatusViewModel(isIdevice: _installationMethod == 1)

		if !isSharing, _installationMethod == 0 {
			_server = ServerInstaller(
				app: app, viewModel: viewModel,
				serverMethod: _serverMethod, localhostOnly: useLocalhost ? true : nil
			)
		}
	}

	deinit {
        _preparedPackage?.cancel()
        _runTask?.cancel()
        _fallbackTask?.cancel()
        _confirmationTask?.cancel()
		_progressTask?.cancel()
		_declineCheck?.cancel()
		if let _declineObserver { NotificationCenter.default.removeObserver(_declineObserver) }
	}

	func start(completion: @escaping (Result<Outcome, Error>) -> Void) {
		guard _completion == nil, !_hasFinished else { return }
		_completion = completion

		guard _isSharing || app.identifier != Bundle.main.bundleIdentifier || _installationMethod == 1 else {
			_finish(.failure(Self.error(.localized("You cannot update '%@' with itself, please use an alternative tool to update it.", arguments: Bundle.main.name))))
			return
		}

        if !_isSharing, let identifier = app.identifier {
            _installBaseline = .init(app: _probe.installedApp(for: identifier))
        }
		_statusObserver = viewModel.$status
			.receive(on: DispatchQueue.main)
			.sink { [weak self] in self?._handle($0) }

		_runTask = Task { await _run() }
	}

	/// Stops without reporting an outcome; the caller has already moved on.
    func stop() {
        _hasFinished = true
        onPackaged = nil
        onWorkflowStage = nil
        onConfirmationReason = nil
        _preparedPackage?.cancel()
        _preparedPackage = nil
        _packageArchive = nil
        let server = _server
        _server = nil
        if let server { Task { await server.stop() } }
        _runTask?.cancel()
        _runTask = nil
        _fallbackTask?.cancel()
        _fallbackTask = nil
        _confirmationTask?.cancel()
        _confirmationTask = nil
		_completion = nil
		_disarmDeclineWatch()
		_statusObserver = nil
		_progressTask?.cancel()
		_progressTask = nil
	}

	// MARK: Pipeline

	private func _run() async {
		let keepAlive = BackgroundTaskManager(
			taskName: "Install",
			expirationTitle: .localized("Installation continuing"),
			expirationBody: .localized("The installation will continue when you reopen the app")
		)
		keepAlive.start()
		defer { keepAlive.stop() }

		do {
			if !_isSharing {
				guard let method = InstallMethodKind.selected(forStoredValue: _installationMethod) else {
					throw Self.error(.localized("Unknown installation method. Choose OTA, pairing/IDevice or embedded guest import in Settings."))
				}
				if method == .liveContainer, !EmbeddedContainerRuntime.isAvailable {
					throw Self.error(InstallPreflight.detail(for: .init(method: method,
						readiness: InstallPreflight.readiness(for: method, .init()))))
				}
				if method == .idevice, !FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) {
					throw Self.error(.localized("No pairing file. Import one in Settings → Installation → Pairing file and VPN setup, then connect the VPN."))
				}
			}
            let prepared: PreparedInstallationPackage
            if let pending = _preparedPackage {
                prepared = try await pending.value
            } else {
                prepared = try await _createPackage()
            }
            _preparedPackage = nil
            try Task.checkCancellation()
            guard !_hasFinished else { return }
            _packageArchive = prepared.archive
            let packageUrl = prepared.url
            let exported = prepared.exported
            // Hold the lease through native uploads/staging even if Stop clears properties.
            defer { withExtendedLifetime(prepared.archive) {} }
            hasPackaged = true
            onPackaged?()

			guard !_isSharing else {
				_finish(.success(.exported(_useShareSheet ? exported : nil)))
				return
			}

			switch _installationMethod {
			case 1:
				try await InstallationProxy(viewModel: viewModel)
					.install(at: packageUrl, suspend: app.identifier == (Bundle.main.bundleIdentifier ?? ""))
			case 2:
				let accepted = try await Task.detached(priority: .userInitiated) {
					try EmbeddedContainerRuntime.stageIPA(packageUrl)
				}.value
				guard accepted else {
					throw Self.error(.localized("The host could not stage the guest IPA. Complete or discard any previous prepared import, check free space and retry."))
				}
				// Do not restart here: the caller must finish its task and request consent.
				_finish(.success(.guestImportPrepared))
			case 0:
				await _serveForOTA(packageUrl)
			default:
				throw Self.error(.localized("Unknown installation method."))
			}
		} catch {
			_progressTask?.cancel()
			_finish(.failure(error))
		}
	}

	/// Copying and zipping the bundle stays off the main actor; both are long and fully blocking.
	private func _createPackage() async throws -> PreparedInstallationPackage {
        let app = app
        // Resolve managed-object metadata only on the main actor, before file work.
        guard let source = Storage.shared.getAppDirectory(for: app) else {
            throw SigningFileHandlerError.appNotFound
        }
        let exportName = app.name
        let exportVersion = app.version
        let viewModel = viewModel
        let isSharing = _isSharing
        let useShareSheet = _useShareSheet
        let compressForTransfer = !isSharing && _installationMethod == 1
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let archive = try InstallationArchive()
            let handler = ArchiveHandler(app: app, viewModel: viewModel, workspace: archive.directory)
            try await handler.move(from: source)
            try Task.checkCancellation()
            let package = try await handler.archive(compressForTransfer: compressForTransfer)
            try Task.checkCancellation()
            // Once zipped, the original library and IPA are enough; drop the extra Payload copy.
            try FileManager.default.removeItem(at: archive.directory.appendingPathComponent("Payload"))
            let exported: URL?
            if isSharing {
                exported = try IPAExportNaming.movePackage(package, to: FileManager.default.archives,
                    name: exportName, version: exportVersion)
                if !useShareSheet {
                    await MainActor.run {
                        if let shared = FileManager.default.archives.toSharedDocumentsURL() {
                            UIApplication.open(shared)
                        }
                    }
                }
            } else {
                exported = nil
            }
            return PreparedInstallationPackage(url: package, exported: exported, archive: archive)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

	private func _serveForOTA(_ packageUrl: URL) async {
		guard let server = _server else {
			_handleServerFailure(
				packageUrl: packageUrl,
				Self.error(.localized("Could not build the installation link, check your connection and try again."))
			)
			return
		}

        guard !_hasFinished, !Task.isCancelled else { return }
        server.packageArchive = _packageArchive
		server.packageUrl = packageUrl

		if _serverMethod == 1 {
			viewModel.status = .sendingManifest
			server.manifestUrl = await ManifestService.resolve(for: app, payload: server.payloadEndpoint)
		}

        guard !_hasFinished, !Task.isCancelled else { return }
		await server.start()
        guard !_hasFinished, !Task.isCancelled else {
            await server.stop()
            return
        }

		var failure = server.startupError
		if failure == nil {
			failure = await server.selfCheck()
		}

        guard !_hasFinished, !Task.isCancelled else { return }
		if let failure {
			_handleServerFailure(packageUrl: packageUrl, failure)
		} else {
			viewModel.status = .ready
		}
	}

	/// One path for every local-server failure (server object failed to build,
	/// failed startup, failed self check): try a wired idevice install when a
	/// pairing exists, otherwise surface the cause with the actionable wording
	/// and the Semi Local retry.
	private func _handleServerFailure(packageUrl: URL, _ failure: Error) {
        guard !_hasFinished, !Task.isCancelled else { return }
		let pairingExists = FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())
		if pairingExists {
            _didAttemptIdeviceFallback = true
            installationPhase = .downloading
			FileLogger.log("Server setup failed (\(failure.localizedDescription)), falling back to idevice installation", category: "install")
			SigningLog.shared.info(.localized("Server failed, falling back to idevice installation…"), category: "install")
            let archive = _packageArchive
            _fallbackTask = Task {
                defer { withExtendedLifetime(archive) {} }
                do {
                    try Task.checkCancellation()
					try await InstallationProxy(viewModel: viewModel)
						.install(at: packageUrl, suspend: app.identifier == (Bundle.main.bundleIdentifier ?? ""))
				} catch {
					FileLogger.error("idevice fallback failed: \(error.localizedDescription)", category: "install")
					_finish(.failure(error))
				}
			}
			return
		}
		viewModel.status = .broken(_serverMethod == 0 ? ServerInstaller.LocalInstallError.unavailable(failure) : failure)
	}

	// MARK: Status

	private func _handle(_ status: InstallerStatusViewModel.InstallerStatus) {
        guard !_hasFinished else { return }
		switch status {
		case .ready where _installationMethod == 0:
            onWorkflowStage?(.waitingForIOS)
			_openInstall(_serverMethod == 0 ? _server?.iTunesLink : _server?.iTunesLinkExternal)
		case .sendingManifest:
            onWorkflowStage?(.waitingForIOS)
			_armDeclineWatch()
		case .sendingPayload:
            onWorkflowStage?(.installing)
			isPresentingFallbackPage = false
			_disarmDeclineWatch()
            // Begin observing before the transfer completes; small installs can
            // finish before its HTTP completion callback reaches the main actor.
            if _installationMethod == 0, !_didAttemptIdeviceFallback { _startProgressPolling() }
		case .installing where _installationMethod == 0 && !_didAttemptIdeviceFallback:
            _hasServedPayload = true
            onWorkflowStage?(installationPhase == .waitingForStart ? .waitingForIOS : (installationPhase == .verifying ? .verifying : .installing))
			_startProgressPolling()
        case .installing:
            onWorkflowStage?(installationPhase == .verifying ? .verifying : .installing)
		case .completed(let result):
			_progressTask?.cancel()
			_progressTask = nil
			// The IDevice path trusts installd's own phases; corroborate them with the device
			// before telling the user it worked.
			if _installationMethod == 1 || _didAttemptIdeviceFallback, case .success = result {
                guard _confirmationTask == nil else { return }
                // Native completion starts corroboration; it must not expose
                // Completed or remove Skip while that check is still pending.
                installationPhase = .verifying
                viewModel.beginDeviceVerification()
                _confirmationTask = Task { await _confirmIdeviceInstall() }
				return
			}
			_finish(result.map { .installed })
		case .broken(let error):
			_progressTask?.cancel()
			_progressTask = nil
			// OTA got as far as serving and still failed: try installationproxy
			// before reporting the error to the user.
			if _attemptIdeviceFallback(after: error) { return }
			_finish(.failure(error))
		default:
			break
		}
	}

	// Direct open keeps the install to one tap; the redirect page is only for builds that refuse the scheme.
	private func _openInstall(_ link: String?) {
		guard let link, let url = URL(string: link) else {
			_finish(.failure(Self.error(.localized("Could not build the installation link, check your connection and try again."))))
			return
		}

		FileLogger.log("opening \(link)", category: "install")

		if _useNovaDNSDynamic {
			// rewriting resolution is a visible act, so it is logged once per install, with
			// the endpoint that is actually being used.
			FileLogger.log(
				"NovaDNS Dynamic: rewriting resolution for this install via \(NovaDNSDynamic.effectiveRulesURLString) (PPQ enabled)",
				category: "install"
			)
			Task {
				await NovaDNSDynamic.sendRequest(endpoint: "enablePPQ")
			}
		}

		UIApplication.shared.open(url) { [weak self] opened in
			FileLogger.log("itms-services accepted by iOS: \(opened)", category: "install")

			if !opened {
				FileLogger.error("iOS refused the scheme, falling back to the redirect page", category: "install")
				self?.isPresentingFallbackPage = true
			}
		}
	}

	/// Fallback for an OTA install that broke after the server was already up.
	/// Needs a stored pairing (Settings → Tunnel & Pairing) and only runs once.
	private func _attemptIdeviceFallback(after error: Error) -> Bool {
		guard _installationMethod == 0, !_didAttemptIdeviceFallback else { return false }
		guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else { return false }
		guard let packageUrl = _server?.packageUrl else { return false }

		_didAttemptIdeviceFallback = true
        installationPhase = .downloading

		FileLogger.log("OTA install failed (\(error.localizedDescription)), falling back to idevice installation", category: "install")
		SigningLog.shared.info(.localized("Install failed, falling back to idevice installation…"), category: "install")

		viewModel.status = .installing

        let archive = _packageArchive
        _fallbackTask = Task {
            defer { withExtendedLifetime(archive) {} }
            do {
                try Task.checkCancellation()
                try await InstallationProxy(viewModel: viewModel)
					.install(at: packageUrl, suspend: app.identifier == (Bundle.main.bundleIdentifier ?? ""))
			} catch {
				FileLogger.error("idevice fallback failed: \(error.localizedDescription)", category: "install")
				_finish(.failure(error))
			}
		}

		return true
	}

	/// Declining iOS's prompt never reports back, so focus returning with no payload request means cancelled.
	private func _armDeclineWatch() {
		guard _declineObserver == nil else { return }

		_declineObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?._scheduleDeclineCheck(after: 2)
            }
		}

		_scheduleDeclineCheck(after: 60)
	}

	private func _scheduleDeclineCheck(after delay: TimeInterval) {
		_declineCheck?.cancel()

		let work = DispatchWorkItem { [weak self] in
			Task { @MainActor [weak self] in
				guard let self, case .sendingManifest = self.viewModel.status else { return }
				self._finish(.success(.cancelled))
			}
		}

		_declineCheck = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
	}

	private func _disarmDeclineWatch() {
		_declineCheck?.cancel()
		_declineCheck = nil

		if let _declineObserver {
			NotificationCenter.default.removeObserver(_declineObserver)
		}
		_declineObserver = nil
	}

	private func _finish(_ result: Result<Outcome, Error>) {
		guard !_hasFinished else { return }
        _hasFinished = true
        _progressTask?.cancel()
        _progressTask = nil
        _confirmationTask?.cancel()
        _confirmationTask = nil
		// Only an install the device proved may be counted.
		if case .success(let outcome) = result, outcome.countsAsInstall {
            // Publish the terminal card state after _hasFinished is set. Any
            // status observer delivery can no longer start a second confirmation.
            outcome.publishConfirmedCompletion(to: viewModel)
            if let identifier = app.identifier {
                let version: String?
                if case .installedOtherVersion(let reported) = outcome { version = reported }
                else { version = app.version }
                LibraryStatusStore.shared.recordConfirmedInstallation(bundleIdentifier: identifier, version: version)
            }
			Task { await AnalyticsStore.shared.record(.appsInstalled) }
		}
        _disarmDeclineWatch()
		_statusObserver = nil

		let completion = _completion
		_completion = nil
		completion?(result)
	}

	private static func error(_ message: String) -> Error {
		NSError(domain: "Install", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
	}

	// MARK: Progress

	/// Watches one install: progress for the ring, the device for the answer.
	///
	/// This used to end with `if hasStarted, raw == 0 { completed }` — the exact guess audit
	// is about. The loop still drives the ring and the PPQ heartbeat, but the verdict now
	/// comes from `InstallConfirmation` and `InstalledAppProbe`.
	private func _startProgressPolling() {
        guard _progressTask == nil else { return }
        guard let bundleID = app.identifier, !bundleID.isEmpty else {
            _finish(.failure(Self.error(.localized("The device installation cannot be verified because the bundle identifier is missing."))))
            return
        }

		let probe = _probe
		let useNovaDNS = _useNovaDNSDynamic
        let baseline = _installBaseline
		let expectation = InstallConfirmation.Expectation(bundleIdentifier: bundleID, version: app.version)

		_progressTask = Task.detached(priority: .background) { [weak self] in
			let installer = self
			let verdict = await InstallWatcher.watch(
				InstallConfirmation(expectation: expectation),
				probe: probe,
                baseline: baseline,
				progress: { await UIApplication.installProgress(for: bundleID, makeSynchronous: false) },
                startTimeoutEnabled: { await installer?._hasServedPayload ?? true },
				onUpdate: { raw, phase in
					await MainActor.run {
						installer?._handleProgress(raw: raw, phase: phase, useNovaDNS: useNovaDNS)
					}
				}
			)

			guard !Task.isCancelled else { return }

			await MainActor.run {
				installer?._finishConfirmed(verdict)
			}
		}
	}

	/// The ring, and the PPQ heartbeat while the payload is being written.
	private func _handleProgress(raw: Double?, phase: InstallConfirmation.Phase, useNovaDNS: Bool) {
        guard !_hasFinished else { return }
        if installationPhase != phase {
            installationPhase = phase
            switch phase {
            case .waitingForStart: onWorkflowStage?(_hasServedPayload ? .waitingForIOS : .installing)
            case .downloading: onWorkflowStage?(.installing)
            case .verifying: onWorkflowStage?(.verifying)
            case .finished: break
            }
            FileLogger.log("installation phase: \(phase)", category: "install")
        }
		let value: Double
		switch phase {
		case .waitingForStart:
			value = 0
		case .downloading:
			// installd reports 0…1; the part users recognise as installing starts around 0.6.
			value = min(1.0, max(0.0, ((raw ?? 0) - 0.6) / 0.3))
		case .verifying, .finished:
			// Deliberately not 1.0: the device has not confirmed anything yet.
			value = 0.99
		}

		if viewModel.installProgress != value {
			viewModel.installProgress = value
		}

		guard useNovaDNS, phase != .waitingForStart else { return }
		let now = Date()
		if now.timeIntervalSince(_lastPPQRefresh) >= 10 {
			_lastPPQRefresh = now
			Task { await NovaDNSDynamic.sendRequest(endpoint: "enablePPQ") }
		}
	}

	/// The device has spoken: this is the only place an OTA install is reported as done.
	private func _finishConfirmed(_ verdict: InstallConfirmation.Verdict) {
        guard !_hasFinished, !Task.isCancelled else { return }
		_progressTask = nil
        onConfirmationReason?(verdict.diagnosticCode)


		switch verdict {
		case .installed:
			viewModel.installProgress = 1
			_finish(.success(.installed))

		case .installedOtherVersion(let version):
			viewModel.installProgress = 1
			SigningLog.shared.info(
				.localized("Installed, but the device reports version %@.", arguments: version ?? .localized("unknown")),
				category: "install"
			)
			_finish(.success(.installedOtherVersion(version)))

		case .cancelled:
			_finish(.success(.cancelled))

		case .notInstalled, .timedOutWaiting, .timedOutVerifying:
			let error = InstallConfirmation.Failure(verdict: verdict)
			FileLogger.error("install not confirmed: \(verdict)", category: "install")
			// `.broken` keeps the existing recovery path: one idevice attempt, then a failure the
			// queue offers to retry.
			viewModel.status = .broken(error)
		}
	}

	/// Corroborates the IDevice path's `.completed` with the same rules as the OTA path.
	///
	/// There is no progress counter to watch here — installd reported completion itself — so the
	/// engine goes straight to verification and only the device's answer finishes the install.
	private func _confirmIdeviceInstall() async {
        onWorkflowStage?(.verifying)
		guard let bundleID = app.identifier, !bundleID.isEmpty else {
			_finish(.failure(Self.error(.localized("The device installation cannot be verified because the bundle identifier is missing."))))
			return
		}

		var confirmation = InstallConfirmation(
			expectation: .init(bundleIdentifier: bundleID, version: app.version)
		)
		_ = confirmation.beginVerifying(at: Date())

		let verdict = await InstallWatcher.confirm(&confirmation, probe: _probe)
		_finishConfirmed(verdict)
	}
}

extension AppInstaller.Outcome {
    @MainActor
    func publishConfirmedCompletion(to model: InstallerStatusViewModel) {
        guard countsAsInstall else { return }
        model.installProgress = 1
        model.status = .completed(.success(()))
    }

	/// Whether this outcome is an install the device proved. Counting or celebrating anything
	/// else is what was.
	var countsAsInstall: Bool {
		switch self {
		case .installed, .installedOtherVersion:
			true
		case .cancelled, .exported, .guestImportPrepared:
			false
		}
	}
}
