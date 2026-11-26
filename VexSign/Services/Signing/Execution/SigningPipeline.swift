import Foundation
import NimbleExtensions

/// The real pipeline: the same steps `SigningHandler` always ran, in the same order.
/// Both sides of its worker port are value-only so a managed row never crosses the detached task.
struct SigningPipeline: SigningWork, Sendable {
    // Native stdout capture and zsign cache are process-wide, not pipeline-local.
    // Independent service/pipeline instances must therefore share one permit.
    private static let nativeExecutionGate = SigningExecutionGate()
    let executionGate = SigningPipeline.nativeExecutionGate

    func run(
        _ request: SigningWorkRequest,
        reporting: @escaping (SigningEvent) -> Void
    ) async -> Result<LibraryAppReference, Error> {
        let log = SigningLog.shared
        log.reset()
        log.info(.localized("Preparing to sign %@", arguments: request.app.name ?? .localized("app")))
        for notice in request.notices {
            log.warn(notice)
        }

        // Re-resolve the selected certificate on its owning actor immediately before work. Only
        // its opaque URI crossed the boundary; neither the request nor its row is retained here.
        if let rejection = await MainActor.run(body: { SigningIdentityPolicy.rejection(for: request) }) {
            log.error(SigningIdentityPolicy.logLine(for: rejection))
            return .failure(rejection)
        }
        guard request.appReferenceIsValid else {
            return .failure(WorkspaceAccessError.mismatchedRecord)
        }

        let handler = SigningHandler(app: request.app, options: request.options, executionGate: executionGate)
        handler.appCertificateID = request.certificateID
        handler.authorization = request.authorization
        handler.appIconData = request.iconData
        handler.onStage = { reporting(.stage($0)) }
        handler.onSignatureVerified = { reporting(.signatureVerified) }
        handler.onCompatibilityRemoved = { reporting(.compatibilityRemoved($0)) }
        handler.overridesBlockingPreflightIssues = request.overridesBlockingPreflightIssues

        do {
            try await handler.copy()
            try Task.checkCancellation()

            try await handler.modify()

            guard let artifact = handler.signedArtifact else {
                throw SigningFileHandlerError.appNotFound
            }

            // Cleanup is observable but cannot turn a committed output into a failed signing run.
            await _clean(handler)
            return .success(artifact)
        } catch {
            // Preserve the operation's primary error; cleanup failure is recorded separately.
            await _clean(handler)
            return .failure(error)
        }
    }

    private func _clean(_ handler: SigningHandler) async {
        do {
            try await handler.clean()
        } catch {
            SigningLog.shared.warn("Signing cleanup failed: " + LogRedaction.redact(error.localizedDescription))
        }
    }
}
