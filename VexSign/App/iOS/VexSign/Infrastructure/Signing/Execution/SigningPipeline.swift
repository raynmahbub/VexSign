import Foundation
import NimbleExtensions

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
