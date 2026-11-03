import Foundation
import Security

/// Audit evidence only, NOT a cached signing permit. Re-evaluate at each protected
/// execution boundary; public trust APIs do not expose an OCSP nextUpdate here.
struct NativeDevelopmentCertificateEvaluation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let ownerDigest: String
    let contextID: UUID
    let certificateSHA256: String
    let evaluatedAt: Date
    let chainDER: [Data]
    fileprivate init(owner: NativeSigningIdentityOwner, contextID: UUID, certificateDER: Data, now: Date, chain: [Data]) {
        ownerDigest = owner.digest; self.contextID = contextID
        certificateSHA256 = NativeSigningIdentityOwner.hash(certificateDER)
        evaluatedAt = now; chainDER = chain
    }
    var description: String { "NativeDevelopmentCertificateEvaluation(redacted; not signing authority)" }
    var debugDescription: String { description }
}

/// Public Security API implementation, offline by default and fail-closed.
/// Positive revocation is REQUIRED, never best-effort or unknown=good. Online
/// access requires a separate single-use owner/context/certificate-bound grant,
/// consumed only after offline Apple chain/purpose validation.
struct NativeDevelopmentCertificateVerifier: Sendable {
    private static let rootPins: Set<String> = [
        "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
        "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
        "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c7566f3017b3a8c488c3653e9179"
    ]

    func evaluate(owner: NativeSigningIdentityOwner, contextID: UUID, certificateDER: Data,
                  issuerCertificates: [Data], now: Date,
                  identityID: UUID? = nil, networkAuthorization: NativeCertificateStatusAuthorization? = nil,
                  clock: @escaping @Sendable () -> Date = { Date() },
                  checkCurrent: @escaping @Sendable () async throws -> Void) async throws -> NativeDevelopmentCertificateEvaluation {
        let check: @Sendable () async throws -> Void = {
            try Task.checkCancellation()
            do { try await checkCurrent() }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw NativeDevelopmentCertificateError.contextChanged
            }
            try Task.checkCancellation()
        }
        do {
            try await check()
            guard now.timeIntervalSince1970.isFinite, !certificateDER.isEmpty, certificateDER.count <= 64 * 1024,
                  issuerCertificates.count <= 7,
                  issuerCertificates.allSatisfy({ !$0.isEmpty && $0.count <= 64 * 1024 }) else { throw NativeDevelopmentCertificateError.invalidInput }
            let allDER = [certificateDER] + issuerCertificates
            guard Set(allDER).count == allDER.count else { throw NativeDevelopmentCertificateError.invalidInput }
            try NativeDevelopmentCertificatePurpose.requireDevelopment(certificateDER, teamIdentifier: owner.teamIdentifier)
            let certificates = try allDER.map { data -> SecCertificate in
                guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else { throw NativeDevelopmentCertificateError.trustRejected }
                return certificate
            }
            try await check()
            // First authenticate Apple's actual chain/purpose with networking off.
            // No caller root is installed as an anchor and user overrides reject.
            let baseline = try makeTrust(certificates, policies: [SecPolicyCreateBasicX509()], now: now)
            guard SecTrustEvaluateWithError(baseline, nil) else { throw NativeDevelopmentCertificateError.trustRejected }
            let initialChain = try requireAppleChain(baseline, leaf: certificateDER)
            try await check()
            var onlineID: UUID?
            if let networkAuthorization {
                guard let identityID else { throw NativeCertificateStatusConsentError.consentRequired }
                onlineID = try await networkAuthorization.gate.begin(networkAuthorization.consent,
                    owner: owner, contextID: contextID, identityID: identityID, certificate: certificateDER,
                    flow: networkAuthorization.flow, now: clock())
            }
            do {
                try await check()
                if let onlineID, let networkAuthorization { try await networkAuthorization.gate.requireCurrent(onlineID, now: clock()) }
                var flags = CFOptionFlags(kSecRevocationUseAnyAvailableMethod | kSecRevocationRequirePositiveResponse)
                if onlineID == nil { flags |= CFOptionFlags(kSecRevocationNetworkAccessDisabled) }
                guard let revocation = SecPolicyCreateRevocation(flags) else { throw NativeDevelopmentCertificateError.positiveRevocationRequired }
                let checked = try makeTrust(initialChain, policies: [SecPolicyCreateBasicX509(), revocation], now: now, network: onlineID != nil)
                guard SecTrustEvaluateWithError(checked, nil) else { throw NativeDevelopmentCertificateError.positiveRevocationRequired }
                let finalChain = try requireAppleChain(checked, leaf: certificateDER)
                try await check()
                if let onlineID, let networkAuthorization { try await networkAuthorization.gate.requireCurrent(onlineID, now: clock()) }
                let result = NativeDevelopmentCertificateEvaluation(owner: owner, contextID: contextID, certificateDER: certificateDER,
                    now: now, chain: finalChain.map { SecCertificateCopyData($0) as Data })
                if let onlineID, let networkAuthorization { await networkAuthorization.gate.finish(onlineID) }
                return result
            } catch {
                if let onlineID, let networkAuthorization { await networkAuthorization.gate.finish(onlineID) }
                throw error
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeDevelopmentCertificateError { throw safe }
            if let safe = error as? NativeCertificateStatusConsentError { throw safe }
            throw NativeDevelopmentCertificateError.trustRejected
        }
    }

    private func makeTrust(_ certificates: [SecCertificate], policies: [SecPolicy], now: Date, network: Bool = false) throws -> SecTrust {
        var result: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, policies as CFArray, &result) == errSecSuccess,
              let trust = result, SecTrustSetNetworkFetchAllowed(trust, network) == errSecSuccess,
              SecTrustSetVerifyDate(trust, now as CFDate) == errSecSuccess else { throw NativeDevelopmentCertificateError.trustRejected }
        return trust
    }
    private func requireAppleChain(_ trust: SecTrust, leaf: Data) throws -> [SecCertificate] {
        var result = SecTrustResultType.invalid
        guard SecTrustGetTrustResult(trust, &result) == errSecSuccess, result == .unspecified,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], chain.count == 3,
              SecCertificateCopyData(chain[0]) as Data == leaf,
              Self.rootPins.contains(NativeSigningIdentityOwner.hash(SecCertificateCopyData(chain[2]) as Data)) else { throw NativeDevelopmentCertificateError.trustRejected }
        try NativeDevelopmentCertificatePurpose.requireWWDR(SecCertificateCopyData(chain[1]) as Data)
        return chain
    }
}
