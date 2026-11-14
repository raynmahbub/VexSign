import Foundation

public enum NativeProvisioningError: Error, Equatable, Sendable {
    case invalidRequest, unsupportedMembership, contextChanged
    case consentRequired, providerFailed, inventoryRejected, requestFailed, storageUnavailable
}

/// Explicitly supplied by the caller; never discovered from advertising/vendor
/// identifiers and never forwarded to the anisette provider. Not persisted here.
public struct NativeAccountProvisioningRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let deviceIdentifier: String
    public let bundleIdentifiers: [String]
    public var description: String { "NativeAccountProvisioningRequest(redacted)" }
    public var debugDescription: String { description }

    public init(deviceIdentifier: String, bundleIdentifiers: [String]) throws {
        let legacy = deviceIdentifier.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil
        let modern = deviceIdentifier.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{16}$", options: .regularExpression) != nil
        guard ((deviceIdentifier.utf8.count == 40 && legacy) || (deviceIdentifier.utf8.count == 25 && modern)), !bundleIdentifiers.isEmpty, bundleIdentifiers.count <= 32,
              Set(bundleIdentifiers.map { $0.lowercased() }).count == bundleIdentifiers.count,
              bundleIdentifiers.allSatisfy(Self.isBundleIdentifier) else {
            throw NativeProvisioningError.invalidRequest
        }
        self.deviceIdentifier = deviceIdentifier
        self.bundleIdentifiers = bundleIdentifiers.sorted()
    }

    static func isBundleIdentifier(_ value: String) -> Bool {
        guard value.utf8.count <= 255, value.contains(".") else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

/// Read-only preview, deliberately not Codable or an executable authorization.
/// It does not assert account quotas, entitlements, profile validity or signing
/// availability. A later executor must revalidate before EACH remote mutation.
public struct NativeAccountProvisioningPlan: Equatable, Sendable {
    public let contextID: UUID
    public let teamIdentifier: String
    public let observedAt: Date
    public let expiresAt: Date
    public let requiresDeviceRegistration: Bool
    public let appIDsToRegister: [String]
    public let existingAppIdentifiers: [String]
    public let remoteCertificateCount: Int
    // A server certificate never proves this device possesses its private key.
    public let requiresLocallyOwnedSigningIdentity: Bool
    // Even a listed profile is not reusable until CMS/identity/UDID/entitlements
    // are validated. This preview never silently selects a portal profile.
    public let profileBundleIdentifiersToPrepare: [String]
}

struct SideSignProvisioningInventory: Sendable {
    let deviceRegistered: Bool
    let appIdentifiers: Set<String>
    let certificateCount: Int
    let validUntil: Date?

    init(deviceRegistered: Bool, appIdentifiers: Set<String>, certificateCount: Int, validUntil: Date? = nil) {
        self.deviceRegistered = deviceRegistered
        self.appIdentifiers = appIdentifiers
        self.certificateCount = certificateCount
        self.validUntil = validUntil
    }

    func plan(request: NativeAccountProvisioningRequest, contextID: UUID,
              teamIdentifier: String, now: Date, sessionExpiry: Date) throws -> NativeAccountProvisioningPlan {
        guard now.timeIntervalSince1970.isFinite, sessionExpiry.timeIntervalSince1970.isFinite,
              sessionExpiry > now, validUntil.map({ $0.timeIntervalSince1970.isFinite && $0 > now }) ?? true else {
            throw NativeProvisioningError.contextChanged
        }
        let existing = request.bundleIdentifiers.filter { appIdentifiers.contains($0) }
        return NativeAccountProvisioningPlan(contextID: contextID, teamIdentifier: teamIdentifier,
            observedAt: now, expiresAt: min(min(sessionExpiry, validUntil ?? sessionExpiry), now.addingTimeInterval(120)),
            requiresDeviceRegistration: !deviceRegistered,
            appIDsToRegister: request.bundleIdentifiers.filter { !appIdentifiers.contains($0) },
            existingAppIdentifiers: existing, remoteCertificateCount: certificateCount,
            requiresLocallyOwnedSigningIdentity: true,
            profileBundleIdentifiersToPrepare: request.bundleIdentifiers)
    }
}
