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
enum SigningStage: String, CaseIterable {
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
	/// Compatibility mode removed these profile-incompatible app extensions before signing.
	case compatibilityRemoved([String])
	case finished(Signed)
	case cancelled
	case failed(Error)

	var isTerminal: Bool {
		switch self {
		case .stage, .compatibilityRemoved:
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
	/// issues ("Sign Anyway"). Those issues are exactly what the post-sign inspection reports,
	/// so the run keeps its bundle instead of failing after the tap. Every path that never
	/// shows the preflight sheet — batch, Update All, automation, self-update — leaves this
	/// false and keeps the strict behaviour.
	let overridesBlockingPreflightIssues: Bool

	init(
		id: String = UUID().uuidString,
		app: AppInfoPresentable,
		options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		overridesBlockingPreflightIssues: Bool = false
	) {
		self.id = id
		self.app = app
		self.options = options
		self.icon = icon
		self.certificate = certificate
		self.overridesBlockingPreflightIssues = overridesBlockingPreflightIssues
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
	/// leave no bundle behind.
	func run(_ request: SigningRequest, reporting: @escaping (SigningEvent) -> Void) async -> Result<Signed, Error>
}

// MARK: - Pipeline

/// The real pipeline: the same steps `SigningHandler` always ran, in the same order.
struct SigningPipeline: SigningWork {
	func run(_ request: SigningRequest, reporting: @escaping (SigningEvent) -> Void) async -> Result<Signed, Error> {
		let log = SigningLog.shared
		log.reset()
		log.info(.localized("Preparing to sign %@", arguments: request.name))

		let handler = SigningHandler(app: request.app, options: request.options)
		handler.appCertificate = request.certificate
		handler.appIcon = request.icon
		handler.onStage = { reporting(.stage($0)) }
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

	/// Runs are keyed by request id so a caller can cancel its own and leave the rest alone.
	private var _runs: [String: Task<Void, Never>] = [:]
	private let work: SigningWork

	init(work: SigningWork = SigningPipeline()) {
		self.work = work
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
		guard _runs[request.id] == nil else { return nil }

		let id = request.id
		let work = self.work
		let (events, feeder) = _stream()

		_runs[id] = Task.detached(priority: .userInitiated) {
			let result = await work.run(request) { event in
				feeder.yield(event)
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
				onEvent(event)
				if event.isTerminal {
					self?._finish(id)
				}
			}
		}

		return id
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
			.localized("This app is already being signed.")
		}
	}
}
