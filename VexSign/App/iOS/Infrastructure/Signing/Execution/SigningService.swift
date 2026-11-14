//
//  SigningService.swift
//  VexSign
//
//  The one place a signing run starts, reports and stops.
//
//  Before this, `PackageSigningCoordinator.signPackage` spawned an unstructured `Task.detached` and reported
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

// MARK: - Service

@MainActor
final class SigningService {
	static let shared = SigningService()

	/// The capability report for a prospective run.
	///
	/// Every entry point — the signing sheet, batch, Update All, Shortcuts, self-update —
	/// asks this, so none of them can disagree about whether a run is possible, or why it is
	/// not. Enforcement stays where it was: the identity rule lives in the pipeline, and the
    /// sheet's "Sign Anyway" never excuses mandatory profile or entitlement failures.
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
	private let work: any SigningWork<SigningRequest, Signed>
    private let ownership: AppOperationRegistry

	init(work: any SigningWork<SigningRequest, Signed> = SigningPipeline(), ownership: AppOperationRegistry = .shared) {
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
		let useCase = RunSigningUseCase(work: self.work)
		let (events, feeder) = _stream()

		_runs[id] = Task.detached(priority: .userInitiated) {
            await useCase.execute(request) { feeder.yield($0) }

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
