import Foundation

/// The only production implementation of the engine port; no second pipeline or
/// new module is introduced. Pinned wrapper polarity stays at this boundary.
struct ZsignAdapter: SigningEngine {
    func sign(_ request: SigningEngineRequest) -> SigningEngineOutcome {
        ZsignEngine.sign(request)
    }
}

extension SigningEngineRequest {
    var engineEmbedProvision: Bool { !removeProvisioning }
}

extension SigningEngineOutcome {
    /// The wrapper can fail by flag or message, including contradictory results.
    func requireSuccess() throws {
        if let errorMessage {
            throw NSError(domain: "app.vexsign.zsign", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
        guard succeeded else { throw SigningFileHandlerError.engineRefused }
    }
}
