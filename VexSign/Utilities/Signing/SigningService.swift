//
//  SigningService.swift
//  VexSign
//
//  The one place a signing run starts, reports and stops.
//
//  Before this, `FR.signPackageFile` spawned an unstructured `Task.detached` and reported
//  progress through two hard-coded constants. Nothing could stop it: the batch screen's Cancel
//  only prevented the *next* item, and the signing sheet had no affordance at all.
//
//  The pipeline is not rewritten. `SigningHandler` still copies, modifies, signs, verifies and
//  registers in that order; it now reports each stage as it begins and checks for cancellation
//  between them. Ownership of the run — and therefore the ability to cancel it and clean up
//  after it — lives here.
//

import Foundation
import NimbleExtensions
import UIKit

// MARK: - Stage

/// The real stages of a signing run, in the order they happen.
///
/// `Codable` because the execution trace is persisted in `TaskContext`: the signing sheet is
/// dismissed the moment a run succeeds, so the evidence of what actually ran has to outlive it.
/// The raw values are the on-disk form and must stay stable.
enum SigningStage: String, CaseIterable, Codable {
	case copying
	case modifying
	case thinning
	case injecting
	case signing
	case verifying
	case registering

	var title: String {
		switch self {
		case .copying:
			.localized("Copying the bundle")
		case .modifying:
			.localized("Modifying the bundle")
		case .thinning:
			.localized("Thinning binaries")
		case .injecting:
			.localized("Injecting tweaks")
		case .signing:
			.localized("Signing")
		case .verifying:
			.localized("Verifying the signature")
		case .registering:
			.localized("Adding to the library")
		}
	}

	/// Where the run is, for a determinate progress indicator. Ordered, so a progress bar only
	/// ever moves forwards.
	var progress: Double {
		switch self {
		case .copying:
			0.10
		case .modifying:
			0.25
		case .thinning:
			0.40
		case .injecting:
			0.55
		case .signing:
			0.70
		case .verifying:
			0.85
		case .registering:
			0.95
		}
	}
}

// MARK: - Event

/// What a run reports. The last event of every run is terminal.
enum SigningEvent {
	case stage(SigningStage)
	/// The engine's own post-sign verification accepted the bundle.
	///
	/// This is the only evidence that may mark the Verify step complete. Reaching the
	/// `.verifying` stage says the check started, and overall success says the artifact was
	/// registered — neither one says the signature itself was verified, and "modify without
	/// signing" runs reach `.registering` without verifying anything at all.
	case signatureVerified
	/// Compatibility mode removed these profile-incompatible app extensions before signing.
	case compatibilityRemoved([String])
	case finished(Signed)
	case cancelled
	case failed(Error)

	var isTerminal: Bool {
		switch self {
		case .stage, .signatureVerified, .compatibilityRemoved:
			false
		case .finished, .cancelled, .failed:
			true
		}
	}
}

// MARK: - Request

/// What to sign, and how. A value, so it can cross into the work without dragging the caller's
/// state with it.
struct SigningRequest: Identifiable {
	let id: String
	let app: AppInfoPresentable
	let options: Options
	let icon: UIImage?
	let certificate: CertificatePair?
	/// True when the caller is the signing sheet after the user accepted blocking preflight
	/// issues ("Sign Anyway"). Post-sign profile/entitlement compatibility failures
    /// may be accepted, but structural failures and ignored options still reject output. Every path that never
	/// shows the preflight sheet — batch, Update All, automation, self-update — leaves this
	/// false and keeps the strict behaviour.
	let overridesBlockingPreflightIssues: Bool
	/// Lines the caller needs in this run's log, written as warnings once the run has started.
	///
	/// The pipeline clears the signing console when it begins, so anything a caller logs before
	/// starting is gone before the user can read it. A run that reuses saved settings uses this
	/// to say what it could not reuse.
	let notices: [String]

	init(
		id: String = UUID().uuidString,
		app: AppInfoPresentable,
		options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		overridesBlockingPreflightIssues: Bool = false,
		notices: [String] = []
	) {
		self.id = id
		self.app = app
		self.options = options
		self.icon = icon
		self.certificate = certificate
		self.overridesBlockingPreflightIssues = overridesBlockingPreflightIssues
		self.notices = notices
	}

	var name: String {
		app.name ?? .localized("app")
	}
}

// MARK: - Work

/// The pipeline behind a run. Injected so the service's ordering, cancellation and cleanup can
/// be tested without zsign, a device or a certificate.
protocol SigningWork {
	/// Runs the pipeline, reporting stage and compatibility events synchronously in order.
	///
	/// Contract: honour `Task.isCancelled` between stages, remove anything written for this
	/// request, and return `.failure(CancellationError())` when cancelled. A cancelled run must
	/// leave no bundle behind. Report `.signatureVerified` only when the engine's own
	/// verification accepted the bundle — never as a side effect of finishing.
	func run(_ request: SigningRequest, reporting: @escaping (SigningEvent) -> Void) async -> Result<Signed, Error>
}

// MARK: - Pipeline

/// The real pipeline: the same steps `SigningHandler` always ran, in the same order.
struct SigningPipeline: SigningWork {
    let executionGate = SigningExecutionGate()
	func run(_ request: SigningRequest, reporting: @escaping (SigningEvent) -> Void) async -> Result<Signed, Error> {
		let log = SigningLog.shared
		log.reset()
		log.info(.localized("Preparing to sign %@", arguments: request.name))
		for notice in request.notices {
			log.warn(notice)
		}

		// The identity is decided here, before a byte is copied.
		//
		// Only the Signing screen ran `PreflightChecks`, and only after the user pressed
		// Sign; batch, Update All, Shortcuts and self-update never rendered it. An expired
		// or revoked certificate therefore reached zsign on those paths, produced a bundle
		// iOS refuses to install, and failed minutes later with a signature-shaped error.
		// `overridesBlockingPreflightIssues` intentionally does not excuse this: the
		// preflight's "Sign Anyway" covers profile and entitlement compatibility, which can
		// still install, not an identity that is invalid on its face.
		if let rejection = SigningIdentityPolicy.rejection(for: request) {
			log.error(SigningIdentityPolicy.logLine(for: rejection))
			return .failure(rejection)
		}
		// The certificate's own end date, recorded by the last status check. It is read from
		// the stored snapshot, not fetched: a run must not wait on the network to start.
		if request.options.signingOption == .default,
		   let uuid = request.certificate?.uuid,
		   let rejection = SigningIdentityPolicy.rejection(
			storedSnapshot: CertificateRevocationSnapshot.stored(forCertificateUUID: uuid)
		   ) {
			log.error(SigningIdentityPolicy.logLine(for: rejection))
			return .failure(rejection)
		}

		let handler = SigningHandler(app: request.app, options: request.options, executionGate: executionGate)
		handler.appCertificate = request.certificate
		handler.appIcon = request.icon
		handler.onStage = { reporting(.stage($0)) }
		handler.onSignatureVerified = { reporting(.signatureVerified) }
		handler.onCompatibilityRemoved = { reporting(.compatibilityRemoved($0)) }
		handler.overridesBlockingPreflightIssues = request.overridesBlockingPreflightIssues

		do {
			try await handler.copy()
			try Task.checkCancellation()

			try await handler.modify()
			try? await handler.clean()

			guard let signed = handler.signedApp else {
				throw SigningFileHandlerError.appNotFound
			}

			return .success(signed)
		} catch {
			// Deterministic cleanup: the work directory always, and the moved-but-unregistered
			// bundle when the run failed after `move()` — the guard inside `clean()` decides.
			try? await handler.clean()
			return .failure(error)
		}
	}
}

// MARK: - Service

@MainActor
final class SigningService {
	static let shared = SigningService()

	/// The capability report for a prospective run.
	///
	/// Every entry point — the signing sheet, batch, Update All, Shortcuts, self-update —
	/// asks this, so none of them can disagree about whether a run is possible, or why it is
	/// not. Enforcement stays where it was: the identity rule lives in the pipeline, and the
	/// sheet's "Sign Anyway" still covers profile and entitlement compatibility.
	func capability(for request: SigningRequest) -> SigningCapability {
		SigningCapabilityResolver.report(
			app: request.app,
			options: request.options,
			certificate: request.certificate
		)
	}

	/// Runs are keyed by request id so a caller can cancel its own and leave the rest alone.
	private var _runs: [String: Task<Void, Never>] = [:]
    /// A fresh request ID must not bypass ownership of the same library bundle.
    private var _appOwners: [String: String] = [:]
    private var _leases: [String: AppOperationRegistry.Lease] = [:]
	private let work: SigningWork
    private let ownership: AppOperationRegistry

	init(work: SigningWork = SigningPipeline(), ownership: AppOperationRegistry = .shared) {
		self.work = work
        self.ownership = ownership
	}

	var isSigning: Bool {
		!_runs.isEmpty
	}

	/// Starts a run and returns its id, or nil when that request is already running.
	///
	/// Events arrive on the main actor, in the order they were produced, and the last one is
	/// always terminal — including when the run is cancelled before it does anything. A caller can
	/// therefore rely on exactly one of `.finished`, `.cancelled` or `.failed`.
@discardableResult
	func sign(
		_ request: SigningRequest,
		onEvent: @MainActor @escaping (SigningEvent) -> Void
	) -> String? {
        guard canStart(request) else { return nil }
        let appKey = _appKey(request)
        do { _leases[request.id] = try ownership.acquire(appKey) } catch { return nil }
        if let appKey { _appOwners[appKey] = request.id }

		let id = request.id
		let work = self.work
		let (events, feeder) = _stream()

		_runs[id] = Task.detached(priority: .userInitiated) {
			let result: Result<Signed, Error>
            if Task.isCancelled {
                result = .failure(CancellationError())
            } else {
                result = await work.run(request) { event in
                    // Only the service owns terminal events; work reports progress.
                    if !event.isTerminal { feeder.yield(event) }
                }
            }

			switch result {
			case .success(let signed):
				feeder.yield(.finished(signed))
			case .failure(let error) where error is CancellationError:
				feeder.yield(.cancelled)
			case .failure(let error):
				feeder.yield(.failed(error))
			}

			feeder.finish()
		}

		// One consumer, so the callbacks keep the pipeline's order without a lock of our own.
		Task { @MainActor [weak self] in
			for await event in events {
                // Release before notifying clients: a completion may synchronously retry.
                if event.isTerminal { self?._finish(id) }
                onEvent(event)
			}
		}

		return id
	}

    /// Main-actor admission check, also used before starting UI side effects.
    func canStart(_ request: SigningRequest) -> Bool {
        guard _runs[request.id] == nil else { return false }
        guard let key = _appKey(request) else { return true }
        return _appOwners[key] == nil && !ownership.isBusy(key)
    }

    private func _appKey(_ request: SigningRequest) -> String? {
        AppOperationRegistry.key(request.app)
    }

	func cancel(_ id: String) {
		_runs[id]?.cancel()
	}

	/// Cancels every run in flight. Entries stay until their terminal event arrives, so a second
	/// tap cannot start something new behind the first run's cleanup.
	func cancelAll() {
		for run in _runs.values {
			run.cancel()
		}
	}

	private func _finish(_ id: String) {
        _runs[id] = nil
        _leases[id] = nil
        _appOwners = _appOwners.filter { $0.value != id }
    }

	/// `AsyncStream.makeStream()` is iOS 17; this is the same thing, built the iOS 16 way —
	/// the initialiser hands back the continuation synchronously.
	private func _stream() -> (AsyncStream<SigningEvent>, AsyncStream<SigningEvent>.Continuation) {
		var feeder: AsyncStream<SigningEvent>.Continuation!
		let stream = AsyncStream<SigningEvent>(bufferingPolicy: .unbounded) { feeder = $0 }
		return (stream, feeder)
	}
}

// MARK: - Errors

extension SigningService {
	struct BusyError: LocalizedError {
		var errorDescription: String? {
			.localized("This app is in use by another operation. Wait for it to finish before retrying.")
		}
	}
}
