import Foundation

/// Metadata-only whole-output audit, NOT an execution/install permit or an
/// exportable signed IPA. No bytes, URLs, keys, PKCS12 or reusable trust lease.
struct NativeSignedArchiveAudit: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let ownerDigest: String
    let contextID: UUID
    let targetDigest: String
    let sourceArchiveSHA256: String
    let outputArchiveSHA256: String
    let certificateSHA256: String
    let profileSHA256: String
    let auditedAt: Date
    let expiresAt: Date
    var description: String { "NativeSignedArchiveAudit(redacted; not install authority)" }
    var debugDescription: String { description }
    fileprivate init(handoff: NativeProtectedSigningHandoff, resources: NativeResourceSealEvidence,
                     signature: NativeMainSignatureConsistencyEvidence, now: Date) {
        ownerDigest = handoff.ownerDigest; contextID = handoff.contextID; targetDigest = handoff.targetDigest
        sourceArchiveSHA256 = resources.sourceArchiveSHA256; outputArchiveSHA256 = resources.outputArchiveSHA256
        certificateSHA256 = signature.certificateSHA256; profileSHA256 = resources.profileSHA256
        auditedAt = now; expiresAt = handoff.expiresAt
    }
}

/// Read-only composition. Reauthenticates input/ownership/profile/certificate both
/// before and after detached CPU output verification. Retains the actual backend
/// lifetime while uncooperative work retires. Does not sign, extract or install.
struct NativeSignedArchiveAuditor: Sendable {
    private let validator: NativeProvisioningProfileValidator
    private let clock: @Sendable () -> Date
    init(validator: NativeProvisioningProfileValidator = .init(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.validator = validator; self.clock = clock
    }
    func audit(originalArchive: Data, outputArchive: Data, handoff: NativeProtectedSigningHandoff,
               owner: NativeSigningIdentityOwner, contextID: UUID, target: NativeAccountProfileTarget,
               issuerCertificates: [Data], lifetime: any NativeAccountBackendLifetime,
               statusAuthorization: NativeCertificateStatusAuthorization? = nil,
               ownedIdentity: @escaping @Sendable () async throws -> NativeOwnedProfileIdentity,
               checkAuthority: @escaping @Sendable () async throws -> Void) async throws -> NativeSignedArchiveAudit {
        try validator.requireCMSVerification()
        let clock = self.clock
        let check: @Sendable () async throws -> Void = {
            try Task.checkCancellation()
            guard clock().timeIntervalSince1970.isFinite, clock() < handoff.expiresAt,
                  handoff.ownerDigest == owner.digest, handoff.contextID == contextID,
                  handoff.targetDigest == target.approvalDigest else { throw NativeDevelopmentCertificateError.contextChanged }
            try await checkAuthority()
            try Task.checkCancellation()
            guard clock() < handoff.expiresAt else { throw NativeDevelopmentCertificateError.contextChanged }
        }
        defer { withExtendedLifetime(lifetime) {} }
        try await check()
        guard (22...128 * 1024 * 1024).contains(originalArchive.count),
              (22...128 * 1024 * 1024).contains(outputArchive.count),
              NativeSigningIdentityOwner.hash(originalArchive) == handoff.content.archiveSHA256 else { throw NativeSignedOutputError.unsupportedClaims }
        let factory = NativeProtectedSigningHandoffFactory(validator: validator, clock: clock)
        let fresh = try await factory.prepare(archive: originalArchive, owner: owner, contextID: contextID,
            target: target, profile: handoff.main.profile, issuerCertificates: issuerCertificates,
            authorityExpiresAt: handoff.expiresAt, lifetime: lifetime, statusAuthorization: statusAuthorization,
            ownedIdentity: ownedIdentity, checkAuthority: check)
        guard fresh.main.identityID == handoff.main.identityID,
              fresh.main.certificateSHA256 == handoff.main.certificateSHA256 else { throw NativeSigningIdentityError.identityChanged }
        try await check()
        let worker = Task.detached(priority: .userInitiated) {
            try NativeSignedArchiveAuditor.verifyOutput(originalArchive: originalArchive,
                outputArchive: outputArchive, fresh: fresh, target: target)
        }
        let proofs = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try await check()
        // A past audit/OCSP timestamp cannot authorize this completion. Repeat the
        // concrete current checks, OFFLINE positive-status only (no reused grant).
        let last = try await factory.prepare(archive: originalArchive, owner: owner, contextID: contextID,
            target: target, profile: fresh.main.profile, issuerCertificates: issuerCertificates,
            authorityExpiresAt: handoff.expiresAt, lifetime: lifetime,
            ownedIdentity: ownedIdentity, checkAuthority: check)
        try await check()
        guard last.main.identityID == fresh.main.identityID,
              last.main.certificateSHA256 == proofs.signature.certificateSHA256,
              last.main.profile.cmsSHA256 == proofs.resources.profileSHA256 else { throw NativeSigningIdentityError.identityChanged }
        return NativeSignedArchiveAudit(handoff: last, resources: proofs.resources, signature: proofs.signature, now: clock())
    }

    private static func verifyOutput(originalArchive: Data, outputArchive: Data,
                                     fresh: NativeProtectedSigningHandoff, target: NativeAccountProfileTarget)
        throws -> (resources: NativeResourceSealEvidence, signature: NativeMainSignatureConsistencyEvidence) {
        let resources = try NativeResourceSealVerifier.verify(originalArchive: originalArchive, content: fresh.content,
            outputArchive: outputArchive, expectedProfileCMS: fresh.main.profile.encodedCMS)
        let index = try NativeIPAArchiveIndex.inspect(outputArchive)
        let prefix = fresh.content.appRoot + "/"
        func file(_ path: String, limit: Int) throws -> Data {
            guard let entry = index.entries.first(where: { $0.path == prefix + path && !$0.isDirectory }),
                  entry.expandedCount > 0, entry.expandedCount <= limit else { throw NativeSignedOutputError.unsupportedClaims }
            return try NativeIPAEntryDecoder.decode(archive: outputArchive, entry: entry)
        }
        let executable = try file(fresh.main.executableName, limit: 64 * 1024 * 1024)
        let seal = try file("_CodeSignature/CodeResources", limit: 4 * 1024 * 1024)
        guard NativeSigningIdentityOwner.hash(executable) == resources.executableSHA256,
              NativeSigningIdentityOwner.hash(seal) == resources.codeResourcesSHA256,
              let certificate = fresh.certificateEvaluation.chainDER.first else { throw NativeSignedOutputError.unsupportedClaims }
        let signature = try NativeMainSignatureConsistency.verifyMutationAndSignature(original: fresh.main.executable,
            output: executable, infoPlist: fresh.main.infoPlist, codeResources: seal,
            expectedXML: fresh.main.signingEntitlementsXML, bundleIdentifier: target.bundleIdentifier,
            teamIdentifier: fresh.main.profile.constraints.teamIdentifier, expectedCertificate: certificate)
        guard signature.resourcesSHA256 == resources.codeResourcesSHA256,
              signature.infoSHA256 == fresh.main.infoSHA256,
              signature.certificateSHA256 == fresh.main.certificateSHA256 else { throw NativeSignedOutputError.unsupportedClaims }
        try Task.checkCancellation()
        return (resources, signature)
    }
}
