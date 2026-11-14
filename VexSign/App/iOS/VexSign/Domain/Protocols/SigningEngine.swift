import Foundation

/// Synchronous native-engine seam. The authoritative signing pipeline controls
/// cancellation, execution serialization, verification, and artifact registration.
/// An engine's success flag alone is not signature or installation evidence.
protocol SigningEngine {
    func sign(_ request: SigningEngineRequest) -> SigningEngineOutcome
}
