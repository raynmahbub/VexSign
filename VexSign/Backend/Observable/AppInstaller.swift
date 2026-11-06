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

	private let _isSharing: Bool
	private let _installationMethod = UserDefaults.standard.integer(forKey: "VexSign.installationMethod")
	private let _serverMethod: Int
	private let _useShareSheet = UserDefaults.standard.bool(forKey: "VexSign.useShareSheetForArchiving")
	private let _useNovaDNSDynamic = UserDefaults.standard.bool(forKey: "VexSign.useNovaDNSDynamic")

	private var _server: ServerInstaller?
	private var _progressTask: Task<Void, Never>?
	private var _statusObserver: AnyCancellable?
	private var _completion: ((Result<Outcome, Error>) -> Void)?
	private var _hasFinished = false
	private var _declineObserver: NSObjectProtocol?
	private var _declineCheck: DispatchWorkItem?
	/// One idevice retry per install, so a genuinely broken pair doesn't loop.
	private var _didAttemptIdeviceFallback = false
	/// The device-side evidence that turns "progress ended" into an answer.
	private let _probe: InstalledAppProbing
	private var _lastPPQRefresh = Date()

	var fallbackPageURL: URL? { _server?.pageEndpoint }

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

		_statusObserver = viewModel.$status
			.receive(on: DispatchQueue.main)
			.sink { [weak self] in self?._handle($0) }

		Task { await _run() }
	}

	/// Stops without reporting an outcome; the caller has already moved on.
	func stop() {
		_hasFinished = true
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
			let (packageUrl, exported) = try await _package()
			guard !_hasFinished else { return }

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
	private func _package() async throws -> (package: URL, exported: URL?) {
		let app = app
		let viewModel = viewModel
		let isSharing = _isSharing
		let useShareSheet = _useShareSheet

		return try await Task.detached(priority: .userInitiated) {
			let handler = ArchiveHandler(app: app, viewModel: viewModel)
			try await handler.move()
			let package = try await handler.archive()

			guard isSharing else { return (package, nil) }
			return (package, try await handler.moveToArchive(package, shouldOpen: !useShareSheet))
		}.value
	}

	private func _serveForOTA(_ packageUrl: URL) async {
		guard let server = _server else {
			_handleServerFailure(
				packageUrl: packageUrl,
				Self.error(.localized("Could not build the installation link, check your connection and try again."))
			)
			return
		}

		server.packageUrl = packageUrl

		if _serverMethod == 1 {
			viewModel.status = .sendingManifest
			server.manifestUrl = await ManifestService.resolve(for: app, payload: server.payloadEndpoint)
		}

		await server.start()

		var failure = server.startupError
		if failure == nil {
			failure = await server.selfCheck()
		}

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
		let pairingExists = FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())
		if pairingExists {
			FileLogger.log("Server setup failed (\(failure.localizedDescription)), falling back to idevice installation", category: "install")
			SigningLog.shared.info(.localized("Server failed, falling back to idevice installation…"), category: "install")
			Task {
				do {
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
		switch status {
		case .ready where _installationMethod == 0:
			_openInstall(_serverMethod == 0 ? _server?.iTunesLink : _server?.iTunesLinkExternal)
		case .sendingManifest:
			_armDeclineWatch()
		case .sendingPayload:
			isPresentingFallbackPage = false
			_disarmDeclineWatch()
		case .installing where _installationMethod == 0:
			_startProgressPolling()
		case .completed(let result):
			_progressTask?.cancel()
			_progressTask = nil
			// The IDevice path trusts installd's own phases; corroborate them with the device
			// before telling the user it worked.
			if _installationMethod == 1, case .success = result {
				Task { await _confirmIdeviceInstall() }
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

		FileLogger.log("OTA install failed (\(error.localizedDescription)), falling back to idevice installation", category: "install")
		SigningLog.shared.info(.localized("Install failed, falling back to idevice installation…"), category: "install")

		viewModel.status = .installing

		Task {
			do {
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
		// Only an install the device proved may be counted.
		if case .success(let outcome) = result, outcome.countsAsInstall {
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
		guard _progressTask == nil, let bundleID = app.identifier else { return }

		let probe = _probe
		let useNovaDNS = _useNovaDNSDynamic
		let expectation = InstallConfirmation.Expectation(bundleIdentifier: bundleID, version: app.version)

		_progressTask = Task.detached(priority: .background) { [weak self] in
			let installer = self
			let verdict = await InstallWatcher.watch(
				InstallConfirmation(expectation: expectation),
				probe: probe,
				progress: { await UIApplication.installProgress(for: bundleID) },
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
		_progressTask = nil

		// The device's answer just changed; anything the library cached about this identifier is
		// now the version of the truth that would make it wrong.
		if verdict.provesInstalled, let identifier = app.identifier {
			LibraryStatusStore.shared.invalidate(bundleIdentifier: identifier)
		}

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
			let error = Self.error(verdict.message ?? .localized("The install could not be confirmed."))
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
