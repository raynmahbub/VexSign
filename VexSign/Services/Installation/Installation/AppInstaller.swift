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
    /// How many times the device has been asked whether this install landed; zero until
    /// verification starts. Shown on the card, so a verification that is still waiting is
    /// visibly still working, and kept in the task report.
    @Published private(set) var verificationAttempt = 0
    private var _hasServedPayload = false
    @Published private(set) var hasOpenedInstallHandoff = false
    @Published private(set) var hasStartedPairedInstall = false
    // Shared with the native worker so Stop and submission have one atomic order.
    private let _pairedControl = DeviceInstallationControl()
    private var _otaHandoffAt: Date?
    var installationHandoffAt: Date? { _otaHandoffAt ?? _pairedControl.submittedAt }
    var hasHandedOffInstall: Bool { hasOpenedInstallHandoff || installationHandoffAt != nil }

    /// Freeze submission BEFORE the queue chooses its stopped/cancelled wording.
    /// Main-actor UI callbacks cannot close the Stop/command race by themselves.
    func stopPreparingForMonitoringEnd() -> Bool {
        _pairedControl.stopBeforeSubmission()
        return hasHandedOffInstall
    }
    var isExport: Bool { _isSharing }


	private let _isSharing: Bool
    /// Resolved once per attempt. Settings changes apply to a retry/new installer, never midway
    /// through packaging or after an installation handoff.
    private let _pipeline: InstallationPipeline?
	private let _installationMethod: Int
    private let _routingError: Error?
	private let _serverMethod: Int
	private let _useShareSheet = UserDefaults.standard.bool(forKey: "VexSign.useShareSheetForArchiving")
	private let _useNovaDNSDynamic = UserDefaults.standard.bool(forKey: "VexSign.useNovaDNSDynamic")

    private var _preparedPackage: Task<PreparedInstallationPackage, Error>?
    private var _packageArchive: InstallationArchive?
    private(set) var hasPackaged = false
    var onPackaged: (() -> Void)?
    var onWorkflowStage: ((UnifiedTaskPhase) -> Void)?
    var onConfirmationReason: ((String) -> Void)?
    var onConfirmedApplication: ((InstalledApplicationEvidence) -> Void)?
    private var _pairedRequest: DeviceConnectionRequest?
    private var _pairedDevice: AuthorizedDeviceSnapshot?
    private var _pairedSubmission: DeviceInstallationSubmission?
    private var _pairedTarget: DeviceInstallationTarget?
    private var _confirmedApplication: InstalledApp?
    var expectedDeviceBinding: DeviceSessionBinding? { _pairedRequest?.binding }
    var nativeAcknowledgedAt: Date? { _pairedSubmission?.acknowledgedAt }
    var installationTarget: DeviceInstallationTarget? { _pairedSubmission?.target ?? _pairedTarget }
    var installationPackageSHA256: String? { installationTarget?.packageSHA256 }

    /// Settings changed while prewarming? Discard the snapshot and build afresh.
    var preparationMatchesSettings: Bool {
        let routeMatches: Bool
        if _isSharing {
            routeMatches = true
        } else {
            do { routeMatches = try SigningModeManager.shared.pipeline(for: app) == _pipeline }
            catch { routeMatches = false }
        }
        return routeMatches &&
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
        do { if _sourceLease == nil { _sourceLease = try AppOperationRegistry.shared.acquire(AppOperationRegistry.key(app)) } }
        catch { return }
        _preparedPackage = Task { try await _createPackage() }
    }

	private var _server: ServerInstaller?
	private var _progressTask: Task<Void, Never>?
    private var _verificationDeadlineTask: Task<Void, Never>?
    /// Bounds everything after the payload has been handed to iOS; see `_armMonitoringBackstop`.
    private var _monitoringBackstopTask: Task<Void, Never>?
    private var _installBaselineTask: Task<Void, Never>?
    private var _runTask: Task<Void, Never>?
    private var _confirmationTask: Task<Void, Never>?
    /// Bounds the window between opening iOS's install prompt and the payload being served.
    private var _promptDeadlineTask: Task<Void, Never>?
	private var _statusObserver: AnyCancellable?
	private var _completion: ((Result<Outcome, Error>) -> Void)?
	private var _hasFinished = false
    private var _sourceLease: AppOperationRegistry.Lease?
	/// The device-side evidence that turns "progress ended" into an answer.
    private var _installBaseline: InstallWatcher.Baseline?
	private let _probe: InstalledAppProbing
	private var _lastPPQRefresh = Date()

	var fallbackPageURL: URL? { _server?.pageEndpoint }

    var installationMethodCode: String {
        if _isSharing { return "export" }
        switch _installationMethod {
        case 0: return "OTA"
        case 1: return "paired-device"
        case 2: return "guest-import"
        default: return "unresolved"
        }
    }

	var canRetryUsingLocalhost: Bool { !_isSharing && _installationMethod == 0 && _serverMethod == 0 }

	/// The policy call, static and free of instance state so a test asks the same question the
	/// installer asks. The verdict does not depend on how the attempt was started: an unsigned or
	/// older copy cannot become installable because a caller asked for an in-place update.
	static func inPlaceVerdict(
		for app: AppInfoPresentable,
		runningIdentifier: String?,
		runningVersion: String
	) -> SelfReplacementBlocker? {
		SelfReplacementPolicy.verdict(
			candidate: SelfReplacementCandidate(
				identifier: app.identifier,
				version: app.version,
				isSigned: app.isSigned
			),
			runningIdentifier: runningIdentifier,
			runningVersion: runningVersion
		)
	}

	/// The in-place verdict for a copy of the running app, computed once per attempt.
	///
	/// `nil` means the same-bundle restriction does not apply to this attempt (it is not the running
	/// app, or the copy passed `SelfReplacementPolicy`). Anything else is the reason to refuse, and
	/// it is what the card shows instead of a sentence about "updating with itself".
	private let _inPlaceVerdict: SelfReplacementBlocker?
	private let _isSelfTarget: Bool
	/// Set only by the update sheet's in-place attempt. A library card tapping VexSign itself keeps
	/// the old refusal, because nothing there proved the copy is a newer signed build.
	private let _allowsInPlaceUpdate: Bool

	init(
		app: AppInfoPresentable,
		isSharing: Bool = false,
		useLocalhost: Bool = false,
		allowsInPlaceUpdate: Bool = false,
		probe: InstalledAppProbing = UnavailableInstallationProbe()
	) {
		let runningIdentifier = Bundle.main.bundleIdentifier
		let identifier = app.identifier
		self._allowsInPlaceUpdate = allowsInPlaceUpdate
		self._isSelfTarget = identifier != nil && identifier == runningIdentifier
		self._inPlaceVerdict = Self.inPlaceVerdict(
			for: app,
			runningIdentifier: runningIdentifier,
			runningVersion: Bundle.main.version
		)
        if isSharing {
            _pipeline = nil
            _installationMethod = 0
            _routingError = nil
        } else {
            do {
                let pipeline = try SigningModeManager.shared.pipeline(for: app)
                _pipeline = pipeline
                _installationMethod = pipeline.installationMethodValue
                _routingError = nil
            } catch {
                _pipeline = nil
                _installationMethod = -1
                _routingError = error
            }
        }
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
        _confirmationTask?.cancel()
        _verificationDeadlineTask?.cancel()
        _monitoringBackstopTask?.cancel()
        _installBaselineTask?.cancel()
        _promptDeadlineTask?.cancel()
		_progressTask?.cancel()
	}

func start(completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard _completion == nil, !_hasFinished else { return }
        _completion = completion
        if let _routingError {
            _finish(.failure(_routingError))
            return
        }
        do { if _sourceLease == nil { _sourceLease = try AppOperationRegistry.shared.acquire(AppOperationRegistry.key(app)) } }
        catch { _finish(.failure(error)); return }

		// The refusal used to be a sentence about "updating with itself" with no way forward. The
		// rule is the same bundle identifier, and a copy that passed the in-place policy is exactly
		// the case iOS supports: same bundle, higher version, signed here, served locally.
		let inPlaceAllowed = _allowsInPlaceUpdate && _inPlaceVerdict == nil
		guard _isSharing || !_isSelfTarget || _installationMethod == 1 || inPlaceAllowed else {
			let message = _inPlaceVerdict?.message
				?? String.localized("You cannot update '%@' with itself, please use an alternative tool to update it.",
				                    arguments: Bundle.main.name)
			_finish(.failure(Self.error(message)))
			return
		}

        if !_isSharing, _installationMethod != 2,
           let identifier = app.identifier, !identifier.isEmpty {
            _captureInstallBaseline(identifier)
        }
		_statusObserver = viewModel.$status
			.receive(on: DispatchQueue.main)
			.sink { [weak self] in self?._handle($0) }

		_runTask = Task { await _run() }
	}

    /// Capture the pre-install state away from the main actor. Until the read
    /// finishes, an explicit unknown baseline prevents the watcher from taking
    /// a second synchronous snapshot on its polling path. A late/unavailable
    /// result can reduce confirmation evidence, but must never block the UI.
    private func _captureInstallBaseline(_ identifier: String) {
        _installBaseline = .init(app: nil)
        _installBaselineTask?.cancel()
        let probe = _probe
        _installBaselineTask = Task.detached(priority: .utility) { [weak self] in
            let baselineApp = await probe.installedAppWithTimeout(for: identifier)
            let baseline = InstallWatcher.Baseline(app: baselineApp)
            guard !Task.isCancelled else { return }
            // Re-capture explicitly: the outer `[weak self]` binding is a `var`, and referring to
            // it from this concurrently-executing closure is an error in the Swift 6 language mode.
            await MainActor.run { [weak self] in
                guard let self, !self._hasFinished else { return }
                self._installBaseline = baseline
                self._installBaselineTask = nil
            }
        }
    }

	/// Stops without reporting an outcome; the caller has already moved on.
    func stop(preserveHandoff: Bool = false) {
        _ = stopPreparingForMonitoringEnd()
        _hasFinished = true
        _sourceLease = nil
        onPackaged = nil
        onWorkflowStage = nil
        onConfirmationReason = nil
        onConfirmedApplication = nil
        _preparedPackage?.cancel()
        _preparedPackage = nil
        _packageArchive = nil
        let server = _server
        _server = nil
        if let server {
            if preserveHandoff && hasOpenedInstallHandoff {
                // Stopping observation cannot withdraw an OTA request. Keep its server and
                // archive alive for a bounded handoff window, including an in-flight transfer.
                Task {
                    _ = await InstallDeadlineBudget.wait(seconds: InstallConfirmation.Limits().monitoringBackstop)
                    await server.stop()
                }
            } else {
                Task { await server.stop() }
            }
        }
        if !(preserveHandoff && _pairedControl.submittedAt != nil) { _runTask?.cancel() }
        _runTask = nil
        _confirmationTask?.cancel()
        _confirmationTask = nil
        _verificationDeadlineTask?.cancel()
        _verificationDeadlineTask = nil
        _monitoringBackstopTask?.cancel()
        _monitoringBackstopTask = nil
        _installBaselineTask?.cancel()
        _installBaselineTask = nil
        _promptDeadlineTask?.cancel()
        _promptDeadlineTask = nil
		_completion = nil
		_statusObserver = nil
		_progressTask?.cancel()
		_progressTask = nil
	}

	// MARK: Pipeline

	private func _run() async {
        let sourceLease = _sourceLease
        defer { withExtendedLifetime(sourceLease) {} }
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
				if method == .idevice {
                    // Refuse before packaging or any native side effect. File
                    // presence and command completion cannot verify an install.
                    guard InstallationAppProxy.hasAcceptedInventoryBridge else {
                        throw DeviceTransportError.inventoryBridgeUnavailable
                    }
                    let request = try await PairingBridge.installationRequest()
                    let device = try await HeartbeatManager.shared.queryDevice(request: request)
                    try Task.checkCancellation()
                    guard PairingBridge.isSelectedForUse(request) else { throw DeviceTransportError.operationCancelled }
                    _pairedRequest = request
                    _pairedDevice = device
                    LibraryStatusStore.shared.selectDevice(binding: request.binding)
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
            _pairedTarget = prepared.pairedTarget
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
                guard let request = _pairedRequest, PairingBridge.isSelectedForUse(request),
                      let target = prepared.pairedTarget else {
                    throw DeviceTransportError.invalidDeviceResponse
                }
                _pairedSubmission = try await InstallationProxy(viewModel: viewModel)
                    .install(at: packageUrl, suspend: app.identifier == (Bundle.main.bundleIdentifier ?? ""),
                        request: request, target: target, control: _pairedControl, onSubmission: { [weak self] _ in
                            Task { @MainActor [weak self] in
                                guard let self, !self._hasFinished else { return }
                                self.hasStartedPairedInstall = true
                                self.onWorkflowStage?(.installing)
                            }
                        })
                guard !_hasFinished, !Task.isCancelled else { return }
                hasStartedPairedInstall = true
                onWorkflowStage?(.installing)
                installationPhase = .verifying
                viewModel.beginDeviceVerification()
                await _confirmIdeviceInstall()
			case 2:
                let worker = Task.detached(priority: .userInitiated) {
                    try EmbeddedContainerRuntime.stageIPA(packageUrl)
                }
                let accepted = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard !_hasFinished else { return }
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
            if _installationMethod == 1, _pairedControl.submittedAt != nil {
                // A lost command response or waiter timeout cannot prove a
                // rejection. Never retry automatically or delete the staged copy
                // while installd may still be reading it.
                _finishConfirmed(.timedOutVerifying, reason: "paired-command-outcome-unknown")
            } else {
                _finish(.failure(error))
            }
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
        let pairedDevice = _pairedDevice
        let expectedIdentifier = app.identifier
        let sourceLease = _sourceLease
        // ArchiveHandler owns the managed app and view model on MainActor. The
        // detached worker captures only its actor reference and Sendable values.
        let archive = try InstallationArchive()
        let handler = ArchiveHandler(app: app, viewModel: viewModel, workspace: archive.directory)
        let worker = Task.detached(priority: .utility) {
            defer { withExtendedLifetime(sourceLease) {} }
            try Task.checkCancellation()
            try await handler.move(from: source)
            try Task.checkCancellation()
            let metadata: PairedInstallationValidation.Metadata?
            if compressForTransfer {
                guard let pairedDevice else { throw DeviceTransportError.invalidDeviceResponse }
                let copiedBundle = archive.directory.appendingPathComponent("Payload", isDirectory: true)
                    .appendingPathComponent(source.lastPathComponent, isDirectory: true)
                metadata = try PairedInstallationValidation.verify(bundleAt: copiedBundle,
                    expectedIdentifier: expectedIdentifier, expectedVersion: exportVersion, device: pairedDevice)
            } else { metadata = nil }
            let package = try await handler.archive(compressForTransfer: compressForTransfer)
            try Task.checkCancellation()
            let pairedTarget: DeviceInstallationTarget?
            if let metadata {
                guard let digest = try FileIntegrity.sha256(of: package, cancellationCheck: { try Task.checkCancellation() }),
                      let target = DeviceInstallationTarget(bundleIdentifier: metadata.identifier,
                        version: metadata.version, build: metadata.build, packageSHA256: digest,
                        authorizationExpiresAt: metadata.authorizationExpiresAt, verifiedDeviceOS: metadata.verifiedDeviceOS) else {
                    throw DeviceTransportError.serviceUnavailable("verified installation archive digest")
                }
                pairedTarget = target
            } else { pairedTarget = nil }
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
            return PreparedInstallationPackage(url: package, exported: exported, archive: archive, pairedTarget: pairedTarget)
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
			let manifestUrl = await ManifestService.resolve(for: app, payload: server.payloadEndpoint)
			guard !_hasFinished, !Task.isCancelled else { return }
			guard let manifestUrl else {
				// Every manifest endpoint failed its positive probe. Do not open an
				// `itms-services` link to an unverified endpoint and call it a request.
				_handleServerFailure(
					packageUrl: packageUrl,
					Self.error(.localized("Could not build the installation link, check your connection and try again."))
				)
				return
			}
			server.manifestUrl = manifestUrl
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

    /// Failure of one transport never authorizes another. The user can select a
    /// supported route in Settings and start a new attempt; no silent paired retry.
    private func _handleServerFailure(packageUrl: URL, _ failure: Error) {
        guard !_hasFinished, !Task.isCancelled else { return }
        viewModel.status = .broken(_serverMethod == 0 ? ServerInstaller.LocalInstallError.unavailable(failure) : failure)
    }

	private func _handle(_ status: InstallerStatusViewModel.InstallerStatus) {
        guard !_hasFinished else { return }
		switch status {
		case .ready where _installationMethod == 0 && !hasOpenedInstallHandoff:
			_openInstall(_serverMethod == 0 ? _server?.iTunesLink : _server?.iTunesLinkExternal)
		case .sendingManifest:
            // Manifest preparation can precede opening the system URL.
            if hasOpenedInstallHandoff { onWorkflowStage?(.waitingForIOS) }
		case .sendingPayload where _installationMethod == 0:
            // Once streaming starts, the prompt timeout must not terminate a slow transfer.
            _promptDeadlineTask?.cancel()
            _promptDeadlineTask = nil
            _armMonitoringBackstop()
            onWorkflowStage?(.installing)
			isPresentingFallbackPage = false
            // Begin observing before the transfer completes; small installs can
            // finish before its HTTP completion callback reaches the main actor.
            if _installationMethod == 0 { _startProgressPolling() }
		case .installing where _installationMethod == 0:
            _hasServedPayload = true
            if _probe is UnavailableInstallationProbe {
                // Delivery is not installation. There is no supported general app inventory
                // on iOS, so stop rather than manufacture progress or a success verdict.
                _finishConfirmed(.timedOutVerifying, reason: "supported-installation-inventory-unavailable")
                return
            }
            _armMonitoringBackstop()
            onWorkflowStage?(installationPhase == .verifying ? .verifying : .installing)
			_startProgressPolling()
        case .installing:
            onWorkflowStage?(installationPhase == .verifying ? .verifying : .installing)
		case .completed(let result):
            // The server finishing an over-the-air transfer means the package was delivered,
            // not that iOS installed it. When the device can be asked, the watcher that is
            // already running keeps asking, bounded by its own limits and the monitoring
            // backstop, and its verdict ends the attempt. Stopping here ended every
            // over-the-air install as unconfirmed seconds after the download.
            if _installationMethod == 0, case .success = result,
               !(_probe is UnavailableInstallationProbe) {
                // A confirmed install publishes "completed" itself; that must not restart
                // the watcher for an attempt that already has its answer.
                guard !_hasFinished else { return }
                _hasServedPayload = true
                _armMonitoringBackstop()
                _startProgressPolling()
                return
            }
			_progressTask?.cancel()
			_progressTask = nil
			// The IDevice path trusts installd's own phases; corroborate them with the device
			// before telling the user it worked.
			if _installationMethod == 1, case .success = result {
                guard _confirmationTask == nil else { return }
                // Native completion starts corroboration; it must not expose
                // Completed or remove Skip while that check is still pending.
                installationPhase = .verifying
                viewModel.beginDeviceVerification()
                _confirmationTask = Task { await _confirmIdeviceInstall() }
				return
			}
            // An OTA transport callback is not a native installation acknowledgement.
            if _installationMethod == 0, case .success = result {
                _finishConfirmed(.timedOutVerifying, reason: "ota-completion-not-authoritative")
            } else {
                switch result {
                case .failure(let error): _finish(.failure(error))
                case .success:
                    _finishConfirmed(.timedOutVerifying, reason: "installation-evidence-unavailable")
                }
            }
		case .broken(let error):
			_progressTask?.cancel()
			_progressTask = nil
            // Stop this attempt, without changing transport or approval scope.
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

		FileLogger.log("opening OTA installation handoff", category: "install")

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

        _otaHandoffAt = Date()
        hasOpenedInstallHandoff = true
        onWorkflowStage?(.waitingForIOS)
		// Bound the window this opens. iOS shows its own alert and never reports the answer
		// back, so nothing downstream is counting until the payload is actually served.
		_armPromptDeadline()

		UIApplication.shared.open(url) { [weak self] opened in
			FileLogger.log("itms-services accepted by iOS: \(opened)", category: "install")

            guard let self, !self._hasFinished else { return }
			if !opened {
				FileLogger.error("iOS refused the scheme, falling back to the redirect page", category: "install")
				self.isPresentingFallbackPage = true
			}
		}
	}

	/// The bound on the OTA prompt window, and the reason an install card can no longer spin
	/// forever.
	///
	/// Between opening iOS's install prompt and the payload being served, nothing in this
	/// pipeline is counting: the confirmation watcher has not started, and its own start timeout
	/// is deliberately suppressed while the transfer has not begun (`startTimeoutEnabled` reports
	/// `_hasServedPayload`). A dismissed prompt, or iOS failing to reach the local server,
	/// therefore used to leave the sheet showing "Installing" with no way out but Skip.
	///
	/// The outcome is `.timedOutWaiting`: no start was observed. It is not proof of
    /// success, rejection, or the user's decision. `Limits.start` is reused rather than a new constant because it is already the tested
	/// bound for how long a prompt may sit unanswered.
	private func _armPromptDeadline() {
		guard _promptDeadlineTask == nil, !_hasFinished else { return }
		let seconds = InstallConfirmation.Limits().start
		_promptDeadlineTask = Task { [weak self] in
            guard await InstallDeadlineBudget.wait(seconds: seconds) else { return }
			// Serving the payload hands the bound to the confirmation watcher, which applies its
			// own start and verify limits from there.
			guard let self, !self._hasFinished, !self._hasServedPayload else { return }
			self._promptDeadlineTask = nil
			self._finishConfirmed(.timedOutWaiting)
		}
	}


    /// Validates the live paired route against the selected session, frozen target and the
    /// exact device record read after native acknowledgement. No other route can manufacture
    /// this evidence.
    private func _hasExactPairedDeviceEvidence(notAfter: Date) -> Bool {
        guard _installationMethod == 1,
              let submission = _pairedSubmission,
              let request = _pairedRequest,
              let binding = request.binding,
              PairingBridge.isSelectedForUse(request),
              submission.binding == binding,
              let expectedBundleIdentifier = app.identifier,
              submission.target.bundleIdentifier == expectedBundleIdentifier,
              submission.target.version == app.version,
              let application = _confirmedApplication,
              application.isInstalled, !application.isPlaceholder,
              application.bundleIdentifier == expectedBundleIdentifier,
              application.version == submission.target.version,
              application.build == submission.target.build else { return false }
        return application.evidence?.confirms(
            bundleIdentifier: submission.target.bundleIdentifier,
            version: submission.target.version,
            build: submission.target.build,
            binding: binding,
            notBefore: submission.acknowledgedAt,
            notAfter: notAfter
        ) == true
    }

	private func _finish(_ result: Result<Outcome, Error>) {
		guard !_hasFinished else { return }
        if case .success(.installed) = result {
            let method = InstallationEvidenceMethod(code: installationMethodCode)
            let hasExactPairedDeviceEvidence = _hasExactPairedDeviceEvidence(notAfter: Date())
            guard InstallCompletionEvidencePolicy.allowsInstalledOutcome(
                method: method, hasExactPairedDeviceEvidence: hasExactPairedDeviceEvidence
            ) else {
                // Defense in depth: OTA delivery and transport completion are not a device
                // inventory; never promote a private/unbound probe, command response, or
                // unsupported route to library evidence.
                onConfirmationReason?(method.rejectedInstalledReason)
                _confirmedApplication = nil
                installationPhase = .finished(.timedOutVerifying)
                viewModel.installProgress = 0.99
                _finish(.failure(InstallConfirmation.Failure(verdict: .timedOutVerifying)))
                return
            }
        }
        _hasFinished = true
        _sourceLease = nil
        _progressTask?.cancel()
        _progressTask = nil
        _confirmationTask?.cancel()
        _confirmationTask = nil
        _verificationDeadlineTask?.cancel()
        _verificationDeadlineTask = nil
        _monitoringBackstopTask?.cancel()
        _monitoringBackstopTask = nil
        _installBaselineTask?.cancel()
        _installBaselineTask = nil
        _promptDeadlineTask?.cancel()
        _promptDeadlineTask = nil
		// Only an install the device proved may be counted.
		if case .success(let outcome) = result, outcome.countsAsInstall {
            // Publish the terminal card state after _hasFinished is set. Any
            // status observer delivery can no longer start a second confirmation.
            outcome.publishConfirmedCompletion(to: viewModel)
            if let application = _confirmedApplication, let evidence = application.evidence {
                onConfirmedApplication?(evidence)
                LibraryStatusStore.shared.recordInstalledApplicationObservation(application)
            }
			Task { await AnalyticsStore.shared.record(.appsInstalled) }
		}
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
        guard _progressTask == nil, !(_probe is UnavailableInstallationProbe) else { return }
        guard let bundleID = app.identifier, !bundleID.isEmpty else {
            _finish(.failure(Self.error(.localized("The device installation cannot be verified because the bundle identifier is missing."))))
            return
        }

		let probe = _probe
		let useNovaDNS = _useNovaDNSDynamic
        let baseline = _installBaseline
        let build = Storage.shared.getAppDirectory(for: app)
            .flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Info.plist"))?["CFBundleVersion"] as? String }
		let expectation = InstallConfirmation.Expectation(bundleIdentifier: bundleID, version: app.version, build: build)

		// Utility, not background: this loop is what applies every deadline of the install and
		// what moves the card on, and the system may hold background-priority work back for as
		// long as it likes.
		_progressTask = Task.detached(priority: .utility) { [weak self] in
			let installer = self
			let observation = await InstallWatcher.watchObservation(
				InstallConfirmation(expectation: expectation),
				probe: probe,
                baseline: baseline,
				progress: { nil }, // Never query private LaunchServices progress, even with an injected probe.
                startTimeoutEnabled: { await installer?._hasServedPayload ?? true },
				onUpdate: { raw, phase in
					await MainActor.run {
						installer?._handleProgress(raw: raw, phase: phase, useNovaDNS: useNovaDNS)
					}
				},
				onVerificationAttempt: { attempt in
					await MainActor.run {
						installer?._handleVerificationAttempt(attempt)
					}
				}
			)

			guard !Task.isCancelled else { return }

			await MainActor.run {
                // Retain exactly what the watcher read. This is not permission
                // to promote an unsupported OTA/private probe: _finish still
                // enforces the independent method, binding and freshness checks.
                installer?._confirmedApplication = observation.confirmedApplication
				installer?._finishConfirmed(observation.verdict)
			}
		}
	}

    /// Independent UI deadline: the watcher normally applies this bound itself,
    /// but a synchronous private-API probe can stall inside a call and prevent its
    /// loop from checking elapsed time. This actor task still releases the card as
    /// unconfirmed without treating a timeout as installation success.
    ///
    /// The time is counted while the app is running (`InstallDeadlineBudget`). As one sleep it
    /// also ran out while iOS had the app suspended, and then closed the card the moment the
    /// app came back, ahead of the watcher's next check: an install that had finished in the
    /// meantime was reported as unconfirmed with the proof one lookup away.
    private func _armVerificationDeadline() {
        guard _verificationDeadlineTask == nil else { return }
        let seconds = TimeInterval(InstallConfirmation.Limits.defaultVerifySeconds)
        _verificationDeadlineTask = Task { [weak self] in
            guard await InstallDeadlineBudget.wait(seconds: seconds) else { return }
            guard let self, !self._hasFinished, self.installationPhase == .verifying else { return }
            self.installationPhase = .finished(.timedOutVerifying)
            // The watcher did not answer in time, so it is no longer the one deciding: stop it
            // rather than leave it asking the device about an install nobody is waiting on.
            self._progressTask?.cancel()
            self._finishConfirmed(.timedOutVerifying)
        }
    }

    /// The bound on everything that follows handing the payload to iOS.
    ///
    /// Each phase after that has its own limit, but the watcher's loop is what applies them: a
    /// loop that is not being run, or is held inside a device read, applies none.
    /// `_armVerificationDeadline` covers that for verification, once verification has been
    /// reported. Nothing covered waiting for iOS to start, or the counter running, so a card
    /// in either state could stay up with nothing left that would ever take it down.
    ///
    /// The bound is longer than every phase at its own limit, and it is counted while the app
    /// is running, so a watcher that is working always answers first - also when the app comes
    /// back from being suspended with every limit long past. Reaching it is reported as
    /// unconfirmed: the device was not heard from, which is neither a success nor a rejection.
    private func _armMonitoringBackstop() {
        guard _monitoringBackstopTask == nil, !_hasFinished else { return }
        let seconds = InstallConfirmation.Limits().monitoringBackstop
        _monitoringBackstopTask = Task { [weak self] in
            guard await InstallDeadlineBudget.wait(seconds: seconds) else { return }
            guard let self, !self._hasFinished else { return }
            self._monitoringBackstopTask = nil
            self.installationPhase = .finished(.timedOutVerifying)
            self._progressTask?.cancel()
            self._finishConfirmed(.timedOutVerifying, reason: "installation-monitoring-deadline")
        }
    }

    /// One device check is starting. Checks are spaced further apart as they go, so the count
    /// is also what says how long verification has been asking.
    private func _handleVerificationAttempt(_ attempt: Int) {
        guard !_hasFinished, attempt > verificationAttempt else { return }
        verificationAttempt = attempt
        FileLogger.log("installation check \(attempt)", category: "install")
    }

	/// The ring, and the PPQ heartbeat while the payload is being written.
	private func _handleProgress(raw: Double?, phase: InstallConfirmation.Phase, useNovaDNS: Bool) {
        guard !_hasFinished else { return }
        if installationPhase != phase {
            installationPhase = phase
            switch phase {
            case .waitingForStart: onWorkflowStage?(.installing)
            case .downloading: onWorkflowStage?(.installing)
            case .verifying:
                onWorkflowStage?(.verifying)
                _armVerificationDeadline()
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
	private func _finishConfirmed(_ verdict: InstallConfirmation.Verdict, reason: String? = nil) {
        guard !_hasFinished, !Task.isCancelled else { return }
		_progressTask = nil
        onConfirmationReason?(reason ?? verdict.diagnosticCode)
        // The view and task record must see the confirmation verdict, not infer it from
        // the transport's completed callback (which can precede verification).
        installationPhase = .finished(verdict)

		// Which verdicts mean what is a rule, not an installer detail: it lives in
		// `InstallVerdictPolicy` and is tested there. This switch only applies it.
		switch InstallVerdictPolicy.outcome(for: verdict) {
		case .confirmed:
			viewModel.installProgress = 1
			_finish(.success(.installed))

		case .anotherVersion:
			// Presence of another version does not prove this artifact was installed.
			_finish(.failure(InstallConfirmation.Failure(verdict: verdict)))

		case .cancelled:
			_finish(.success(.cancelled))

		case .notConfirmed:
			let error = InstallConfirmation.Failure(verdict: verdict)
			FileLogger.error("install not confirmed: \(verdict) after \(verificationAttempt) device checks", category: "install")
            // Lack of evidence is not proof of rejection. Do not silently
            // reinstall through pairing just because a private lookup is filtered.
            _finish(.failure(error))
		}
	}

    /// Resume observation without interpreting activation as a dialog response.
    func reconcileOnForeground() {
        guard !_hasFinished, hasOpenedInstallHandoff else { return }
        if _hasServedPayload { _startProgressPolling() }
    }

    /// A native command acknowledgement is NOT exact app/version evidence.
    /// Keep corroboration with this owner, never with private LaunchServices.
	private func _confirmIdeviceInstall() async {
        onWorkflowStage?(.verifying)
		guard let bundleID = app.identifier, !bundleID.isEmpty else {
			_finish(.failure(Self.error(.localized("The device installation cannot be verified because the bundle identifier is missing."))))
			return
		}

        guard let submission = _pairedSubmission, let request = _pairedRequest,
              let binding = request.binding, binding == submission.binding,
              submission.target.bundleIdentifier == bundleID, submission.target.version == app.version,
              submission.acknowledgedAt >= submission.submittedAt else {
            _finishConfirmed(.timedOutVerifying, reason: "paired-installed-version-not-verified")
            return
        }
        var limits = InstallConfirmation.Limits()
        limits.unavailableEvidence = limits.verify
        var confirmation = InstallConfirmation(expectation: .init(bundleIdentifier: bundleID,
            version: submission.target.version, build: submission.target.build,
            deviceBinding: binding, evidenceNotBefore: submission.acknowledgedAt), limits: limits)
        _ = confirmation.beginVerifying(at: Date())
        _armVerificationDeadline()
        let verdict = await InstallWatcher.confirm(&confirmation,
            probe: PairedDeviceInstallationProbe(request: request), policy: .pairedDevice,
            onAttempt: { [weak self] attempt in
                await MainActor.run { [weak self] in self?._handleVerificationAttempt(attempt) }
            })
        guard !_hasFinished, !Task.isCancelled else { return }
        _confirmedApplication = confirmation.confirmedApplication
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
		case .installed:
			true
		case .installedOtherVersion, .cancelled, .exported, .guestImportPrepared:
			false
		}
	}
}
