import Foundation

/// The authoritative pipeline's port. Concrete request/artifact types are chosen
/// by the adapter; Domain does not know about UIImage, Core Data, or the engine.
protocol SigningWork<Request, Artifact> {
    associatedtype Request
    associatedtype Artifact

    /// Honour cancellation between stages and clean up before returning failure.
    /// Report signatureVerified only after the actual verifier accepts output.
    /// RunSigningUseCase, not the engine or implementation, emits terminal events.
    func run(_ request: Request, reporting: @escaping (SigningWorkflowEvent<Artifact>) -> Void) async -> Result<Artifact, Error>
}
