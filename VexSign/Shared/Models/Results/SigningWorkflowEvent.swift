import Foundation

/// Progress and an explicit terminal result; a signed artifact is not installation evidence.
enum SigningWorkflowEvent<Artifact: Sendable>: Sendable {
	case stage(SigningStage)
	/// The engine's own post-sign verification accepted the bundle.
	///
	/// This is the only evidence that may mark the Verify step complete. Reaching the
	/// `.verifying` stage says the check started, and overall success says the artifact was
	/// registered — neither one says the signature itself was verified, and "modify without
	/// signing" runs reach `.registering` without verifying anything at all.
	case signatureVerified
	/// The verifier's bounded, non-secret result. Emitted only after the real
	/// verification pass, never inferred from a stage or a finished run.
	case verificationReport(SigningVerificationReport)
	/// Compatibility mode removed these profile-incompatible app extensions before signing.
	case compatibilityRemoved([String])
	case finished(Artifact)
	case cancelled
	case failed(Error)

	var isTerminal: Bool {
		switch self {
		case .stage, .signatureVerified, .verificationReport, .compatibilityRemoved:
			false
		case .finished, .cancelled, .failed:
			true
		}
	}
}
