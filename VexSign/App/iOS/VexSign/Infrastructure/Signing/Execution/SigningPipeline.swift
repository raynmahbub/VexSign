import Foundation
import NimbleExtensions

/// The real pipeline: the same steps `SigningHandler` always ran, in the same order.
struct SigningPipeline: SigningWork {
    let executionGate = SigningExecutionGate()
	func run(_ request: SigningRequest, reporting: @escaping (SigningEvent) -> Void) async -> Result<Signed, Error> {
		let log = SigningLog.shared
		log.reset()
        let name = await MainActor.run { request.name }
		log.info(.localized("Preparing to sign %@", arguments: name))
		for notice in request.notices {
			log.warn(notice)
		}

        // Managed rows are inspected only on their owning actor. The worker
        // gets an immutable app projection; the PKCS#12/profile plan is still
        // independently revalidated inside native ownership before any signing.
        if let rejection = await MainActor.run(body: { SigningIdentityPolicy.rejection(for: request) }) {
            log.error(SigningIdentityPolicy.logLine(for: rejection))
            return .failure(rejection)
        }

        let app: AppInfoPresentable
        do {
            let snapshot: LibraryAppRecord? = try await MainActor.run {
                guard request.app is Signed || request.app is Imported else { return nil }
                return try CoreDataWorkspaceRepository(storage: Storage.shared).appRecord(request.app)
            }
            if let snapshot { app = snapshot } else { app = request.app }
        } catch { return .failure(error) }
        let handler = SigningHandler(app: app, options: request.options, executionGate: executionGate)
        handler.appCertificate = request.certificate
        handler.authorization = request.authorization
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
