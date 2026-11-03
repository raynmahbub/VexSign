import Foundation

/// Internal pre-execution artifact, not a reusable signing/install permit.
/// Retains full archive binding rather than downgrading to main-file metadata.
/// No private key/PKCS12, file URL, engine callback or public export surface.
struct NativeProtectedSigningHandoff: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let ownerDigest: String
    let contextID: UUID
    let targetDigest: String
    let content: NativeVerifiedIPAContent
    let main: NativeAccountSigningCandidate
    let certificateEvaluation: NativeDevelopmentCertificateEvaluation
    let expiresAt: Date
    private let lifetime: any NativeAccountBackendLifetime
    fileprivate init(owner: NativeSigningIdentityOwner, contextID: UUID, target: NativeAccountProfileTarget,
                     content: NativeVerifiedIPAContent, main: NativeAccountSigningCandidate,
                     evaluation: NativeDevelopmentCertificateEvaluation, deadline: Date,
                     lifetime: any NativeAccountBackendLifetime) {
        ownerDigest = owner.digest; self.contextID = contextID; targetDigest = target.approvalDigest
        self.content = content; self.main = main; certificateEvaluation = evaluation
        expiresAt = min(deadline, main.expiresAt); self.lifetime = lifetime
    }
    var description: String { "NativeProtectedSigningHandoff(redacted; execution checks required)" }
    var debugDescription: String { description }
}

/// Read-only assembly before protected signing execution. Missing CMS support
/// blocks before archive/identity/callback/trust operations. The owning bridge
/// must supply its actual live authority callback, namespace lease and deadline.
/// All later side effects still require explicit signing approval and fresh
/// certificate status/context/resource/key checks; this cannot perform signing.
struct NativeProtectedSigningHandoffFactory: Sendable {
    private let validator: NativeProvisioningProfileValidator
    private let clock: @Sendable () -> Date
    init(validator: NativeProvisioningProfileValidator = .init(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.validator = validator; self.clock = clock
    }

    func prepare(archive: Data, owner: NativeSigningIdentityOwner, contextID: UUID,
                 target: NativeAccountProfileTarget, profile: NativeAuthenticatedProvisioningProfile,
                 issuerCertificates: [Data], authorityExpiresAt: Date,
                 lifetime: any NativeAccountBackendLifetime,
                 statusAuthorization: NativeCertificateStatusAuthorization? = nil,
                 ownedIdentity: @escaping @Sendable () async throws -> NativeOwnedProfileIdentity,
                 checkAuthority: @escaping @Sendable () async throws -> Void) async throws -> NativeProtectedSigningHandoff {
        try validator.requireCMSVerification()
        let clock = self.clock
        let check: @Sendable () async throws -> Void = {
            try Task.checkCancellation()
            let now = clock()
            guard now.timeIntervalSince1970.isFinite, authorityExpiresAt.timeIntervalSince1970.isFinite,
                  now < authorityExpiresAt else { throw NativeDevelopmentCertificateError.contextChanged }
            try await checkAuthority()
            try Task.checkCancellation()
            guard clock() < authorityExpiresAt else { throw NativeDevelopmentCertificateError.contextChanged }
        }
        try await check()
        let owned = try await ownedIdentity()
        try await check()
        try requireOwned(owned, target: target, owner: owner, profile: profile)

        // CPU/decoder work is off the caller's actor; cancellation does not let
        // an unretired worker escape its owner's busy slot/namespace lifetime.
        let worker = Task.detached(priority: .userInitiated) {
            try NativeIPAContentVerifier.verify(archive, bundleIdentifier: target.bundleIdentifier)
        }
        let content = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try await check()
        let fresh = try await ownedIdentity()
        try await check()
        try requireOwned(fresh, target: target, owner: owner, profile: profile)
        guard fresh.certificateIdentifier == owned.certificateIdentifier else { throw NativeSigningIdentityError.identityChanged }
        let request = try NativeProfileValidationRequest(teamIdentifier: owner.teamIdentifier,
            bundleIdentifier: target.bundleIdentifier, deviceIdentifier: target.deviceIdentifier,
            certificateDER: fresh.validation.certificateDER, expectedUUID: profile.constraints.uuid)
        let authenticated = try await validator.validate(cms: profile.encodedCMS, request: request, now: clock())
        try await check()
        guard authenticated.cmsSHA256 == profile.cmsSHA256 else { throw NativeSigningAcceptanceError.profileMismatch }
        let evaluation = try await NativeDevelopmentCertificateVerifier().evaluate(owner: owner, contextID: contextID,
            certificateDER: fresh.validation.certificateDER, issuerCertificates: issuerCertificates,
            now: clock(), identityID: target.identityID, networkAuthorization: statusAuthorization, clock: clock, checkCurrent: check)
        try await check()
        let last = try await ownedIdentity()
        try await check()
        try requireOwned(last, target: target, owner: owner, profile: authenticated)
        guard last.certificateIdentifier == fresh.certificateIdentifier else { throw NativeSigningIdentityError.identityChanged }
        let main = try NativeMainAppAcceptance.candidate(infoPlist: content.infoPlist, executable: content.executable,
            executableName: content.executableName, owned: last, profile: authenticated, now: clock())
        try await check()
        return NativeProtectedSigningHandoff(owner: owner, contextID: contextID, target: target,
            content: content, main: main, evaluation: evaluation, deadline: authorityExpiresAt, lifetime: lifetime)
    }

    private func requireOwned(_ owned: NativeOwnedProfileIdentity, target: NativeAccountProfileTarget,
                              owner: NativeSigningIdentityOwner, profile: NativeAuthenticatedProvisioningProfile) throws {
        guard owned.identityID == target.identityID, owned.validation.teamIdentifier == owner.teamIdentifier,
              owned.validation.bundleIdentifier == target.bundleIdentifier,
              owned.validation.deviceIdentifier == target.deviceIdentifier,
              profile.certificateSHA256 == NativeSigningIdentityOwner.hash(owned.validation.certificateDER),
              profile.deviceIdentifier == target.deviceIdentifier,
              profile.constraints.teamIdentifier == owner.teamIdentifier,
              profile.constraints.applicationIdentifier == owner.teamIdentifier + "." + target.bundleIdentifier,
              target.selectedProfileUUID.map({ $0 == profile.constraints.uuid }) ?? true else { throw NativeSigningAcceptanceError.profileMismatch }
    }
}
