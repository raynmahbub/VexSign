import Foundation
import CoreFoundation

public enum NativeProfileValidationError: Error, Equatable, Sendable {
    case invalidRequest, malformedProfile, cmsVerificationUnavailable, cmsRejected
    case contextMismatch, expired, certificateMismatch, unsupportedEntitlements
}

/// Internal constraints only: no credentials or private key, never an anisette
/// provider payload. The certificate must come from the owned durable identity;
/// arbitrary imported certificates belong to a separate signing backend.
struct NativeProfileValidationRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let teamIdentifier: String
    let bundleIdentifier: String
    let deviceIdentifier: String
    let certificateDER: Data
    let expectedUUID: UUID?
    var description: String { "NativeProfileValidationRequest(redacted)" }
    var debugDescription: String { description }

    init(teamIdentifier: String, bundleIdentifier: String, deviceIdentifier: String,
         certificateDER: Data, expectedUUID: UUID? = nil) throws {
        guard teamIdentifier.utf8.count == 10,
              teamIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              !certificateDER.isEmpty, certificateDER.count <= 64 * 1024 else {
            throw NativeProfileValidationError.invalidRequest
        }
        do { _ = try NativeAccountProvisioningRequest(deviceIdentifier: deviceIdentifier, bundleIdentifiers: [bundleIdentifier]) }
        catch { throw NativeProfileValidationError.invalidRequest }
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.deviceIdentifier = deviceIdentifier.uppercased()
        self.certificateDER = certificateDER
        self.expectedUUID = expectedUUID
    }
}

/// A verifier must authenticate CMS SignedData, signed attributes/content digest,
/// the provisioning-signing purpose and Apple-authorized signer chain at `now`.
/// Merely extracting a plist, verifying a self-signed embedded certificate, or
/// trusting an arbitrary system-TLS certificate does NOT satisfy this contract.
/// No implementation is selected yet: production validation fails closed.
protocol NativeProfileCMSVerifying: Sendable {
    func verifyAppleProvisioningCMS(_ cms: Data, now: Date) async throws -> Data
}

/// Deliberately distinct from authenticated-profile output. Even a matching
/// plaintext plist is not a signed profile and cannot authorize signing.
struct NativeProfileConstraintSummary: Equatable, Sendable {
    let uuid: UUID
    let expiresAt: Date
    let applicationIdentifier: String
    let teamIdentifier: String
    // Exactly the requested app's group, never the profile's wildcard grant.
    let keychainAccessGroup: String
}

/// Constructible only by the CMS gate in this file. Still NOT signing readiness:
/// certificate trust/purpose/revocation, nested IPA entitlements, context freshness
/// and install-target authority need their own checks at execution time.
struct NativeAuthenticatedProvisioningProfile: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let constraints: NativeProfileConstraintSummary
    let cmsSHA256: String
    // Retain the exact authenticated envelope for future embedding, not a
    // reconstructed/unsigned plist. Internal only, never a public export API.
    let encodedCMS: Data
    // Bind later artifact handoff to the certificate/device actually checked by
    // this CMS gate, not just another identity with the same team/bundle.
    let certificateSHA256: String
    let deviceIdentifier: String
    fileprivate init(constraints: NativeProfileConstraintSummary, cmsSHA256: String, encodedCMS: Data,
                     certificateSHA256: String, deviceIdentifier: String) {
        self.constraints = constraints; self.cmsSHA256 = cmsSHA256; self.encodedCMS = encodedCMS
        self.certificateSHA256 = certificateSHA256; self.deviceIdentifier = deviceIdentifier
    }
    var description: String { "NativeAuthenticatedProvisioningProfile(redacted)" }
    var debugDescription: String { description }
}

struct NativeProvisioningProfileValidator: Sendable {
    private let verifier: (any NativeProfileCMSVerifying)?
    init(verifier: (any NativeProfileCMSVerifying)? = nil) { self.verifier = verifier }

    /// Explicit internal opt-in only. Default stays unavailable until native
    /// validation/promotion; do not select this merely because a plist parses.
    static func appleCMS() -> Self { Self(verifier: NativeAppleProfileCMSVerifier()) }

    func requireCMSVerification() throws {
        guard verifier != nil else { throw NativeProfileValidationError.cmsVerificationUnavailable }
    }

    func validate(cms: Data, request: NativeProfileValidationRequest, now: Date) async throws -> NativeAuthenticatedProvisioningProfile {
        try Task.checkCancellation()
        guard now.timeIntervalSince1970.isFinite, !cms.isEmpty, cms.count <= 1024 * 1024 else {
            throw NativeProfileValidationError.malformedProfile
        }
        guard let verifier else { throw NativeProfileValidationError.cmsVerificationUnavailable }
        let payload: Data
        do { payload = try await verifier.verifyAppleProvisioningCMS(cms, now: now) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw NativeProfileValidationError.cmsRejected
        }
        try Task.checkCancellation()
        let constraints = try Self.validatePayloadConstraints(payload, request: request, now: now)
        return NativeAuthenticatedProvisioningProfile(constraints: constraints, cmsSHA256: NativeSigningIdentityOwner.hash(cms), encodedCMS: cms,
            certificateSHA256: NativeSigningIdentityOwner.hash(request.certificateDER), deviceIdentifier: request.deviceIdentifier)
    }

    /// Policy parser only, also used for synthetic fixtures. NEVER use its result
    /// in place of `validate(cms:request:now:)` or skip CMS authentication.
    static func validatePayloadConstraints(_ payload: Data, request: NativeProfileValidationRequest,
                                           now: Date) throws -> NativeProfileConstraintSummary {
        guard now.timeIntervalSince1970.isFinite, !payload.isEmpty, payload.count <= 512 * 1024 else {
            throw NativeProfileValidationError.malformedProfile
        }
        let root: [String: Any]
        do {
            guard let value = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [String: Any] else {
                throw NativeProfileValidationError.malformedProfile
            }
            root = value
        } catch { throw NativeProfileValidationError.malformedProfile }
        guard let version = root["Version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: version.objCType)), version == NSNumber(value: 1),
              let rawUUID = root["UUID"] as? String, rawUUID.utf8.count == 36, let uuid = UUID(uuidString: rawUUID),
              let created = root["CreationDate"] as? Date, let expires = root["ExpirationDate"] as? Date,
              created.timeIntervalSince1970.isFinite, expires.timeIntervalSince1970.isFinite,
              let platforms = root["Platform"] as? [String], platforms == ["iOS"] else {
            throw NativeProfileValidationError.malformedProfile
        }
        guard created <= now, expires > now, expires > created else { throw NativeProfileValidationError.expired }
        let team = request.teamIdentifier
        guard request.expectedUUID.map({ $0 == uuid }) ?? true,
              root["TeamIdentifier"] as? [String] == [team],
              root["ApplicationIdentifierPrefix"] as? [String] == [team] else {
            throw NativeProfileValidationError.contextMismatch
        }
        // App Store / enterprise / wildcard / non-iOS profiles are not this
        // free-account development slice. No permissive missing-field defaults.
        if let allDevices = root["ProvisionsAllDevices"] {
            guard strictBoolean(allDevices) == false else { throw NativeProfileValidationError.contextMismatch }
        }
        guard let devices = root["ProvisionedDevices"] as? [String], !devices.isEmpty, devices.count <= 1024,
              devices.allSatisfy({ isDeviceIdentifier($0) }),
              Set(devices.map { $0.uppercased() }).count == devices.count,
              devices.contains(where: { $0.uppercased() == request.deviceIdentifier }) else {
            throw NativeProfileValidationError.contextMismatch
        }
        guard let certificates = root["DeveloperCertificates"] as? [Data], !certificates.isEmpty, certificates.count <= 32,
              certificates.allSatisfy({ !$0.isEmpty && $0.count <= 64 * 1024 }),
              Set(certificates).count == certificates.count,
              certificates.contains(request.certificateDER) else { throw NativeProfileValidationError.certificateMismatch }
        let appID = team + "." + request.bundleIdentifier
        guard let entitlements = root["Entitlements"] as? [String: Any] else {
            throw NativeProfileValidationError.unsupportedEntitlements
        }
        let allowed: Set<String> = ["application-identifier", "com.apple.developer.team-identifier",
                                    "get-task-allow", "keychain-access-groups", "beta-reports-active"]
        guard Set(entitlements.keys).isSubset(of: allowed),
              entitlements["application-identifier"] as? String == appID,
              entitlements["com.apple.developer.team-identifier"] as? String == team,
              strictBoolean(entitlements["get-task-allow"]) == true,
              let groups = entitlements["keychain-access-groups"] as? [String], !groups.isEmpty, groups.count <= 8,
              Set(groups).count == groups.count,
              groups.allSatisfy({ $0 == appID || $0 == team + ".*" }) else {
            throw NativeProfileValidationError.unsupportedEntitlements
        }
        if let beta = entitlements["beta-reports-active"] {
            guard strictBoolean(beta) == false else { throw NativeProfileValidationError.unsupportedEntitlements }
        }
        return NativeProfileConstraintSummary(uuid: uuid, expiresAt: expires, applicationIdentifier: appID,
                                               teamIdentifier: team, keychainAccessGroup: appID)
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func isDeviceIdentifier(_ value: String) -> Bool {
        // Same explicit physical-device grammar as preflight, no vendor/ad ID.
        (try? NativeAccountProvisioningRequest(deviceIdentifier: value, bundleIdentifiers: ["validation.placeholder"])) != nil
    }
}
