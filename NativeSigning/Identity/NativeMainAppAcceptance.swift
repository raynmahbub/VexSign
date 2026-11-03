import Foundation
import CoreFoundation

/// Immutable main-app handoff candidate only. No archive completeness, original
/// signature trust, development-certificate trust/revocation or installation
/// authority is asserted. There is intentionally no signing executor for it yet.
struct NativeAccountSigningCandidate: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let identityID: UUID
    let certificateSHA256: String
    let infoPlist: Data
    let executable: Data
    let executableName: String
    let infoSHA256: String
    let executableSHA256: String
    let signingEntitlementsXML: Data
    let profile: NativeAuthenticatedProvisioningProfile
    let inspectedAt: Date
    let expiresAt: Date
    fileprivate init(identityID: UUID, certificateSHA256: String, infoPlist: Data, executable: Data,
                     executableName: String, signingEntitlementsXML: Data,
                     profile: NativeAuthenticatedProvisioningProfile, now: Date) {
        self.identityID = identityID; self.certificateSHA256 = certificateSHA256
        self.infoPlist = infoPlist; self.executable = executable; self.executableName = executableName
        infoSHA256 = NativeSigningIdentityOwner.hash(infoPlist)
        executableSHA256 = NativeSigningIdentityOwner.hash(executable)
        self.signingEntitlementsXML = signingEntitlementsXML; self.profile = profile
        inspectedAt = now; expiresAt = min(profile.constraints.expiresAt, now.addingTimeInterval(30))
    }
    var description: String { "NativeAccountSigningCandidate(redacted; not signing authority)" }
    var debugDescription: String { description }
}

/// First slice for one main executable, not a whole IPA/ZIP acceptance verdict.
/// Caller must later supply a verified complete archive inventory and fresh owned
/// certificate trust/revocation/context/installation authority before any signing.
struct NativeMainAppAcceptance {
    static func candidate(infoPlist: Data, executable: Data, executableName: String,
                          owned: NativeOwnedProfileIdentity, profile: NativeAuthenticatedProvisioningProfile,
                          now: Date) throws -> NativeAccountSigningCandidate {
        guard now.timeIntervalSince1970.isFinite, now < profile.constraints.expiresAt else { throw NativeSigningAcceptanceError.expired }
        let expected = owned.validation
        let appID = expected.teamIdentifier + "." + expected.bundleIdentifier
        guard profile.constraints.applicationIdentifier == appID,
              profile.constraints.teamIdentifier == expected.teamIdentifier,
              profile.constraints.keychainAccessGroup == appID,
              profile.deviceIdentifier == expected.deviceIdentifier,
              profile.certificateSHA256 == NativeSigningIdentityOwner.hash(expected.certificateDER),
              profile.cmsSHA256 == NativeSigningIdentityOwner.hash(profile.encodedCMS),
              expected.expectedUUID.map({ $0 == profile.constraints.uuid }) ?? true else { throw NativeSigningAcceptanceError.profileMismatch }
        try validateInfo(infoPlist, executableName: executableName, bundleIdentifier: expected.bundleIdentifier)
        let inspected = try NativeMachOInspection.inspect(executable)
        let entitlements = try signingEntitlements(requestedXML: inspected.entitlementsXML, bundleIdentifier: expected.bundleIdentifier,
                                                   applicationIdentifier: appID, teamIdentifier: expected.teamIdentifier)
        return NativeAccountSigningCandidate(identityID: owned.identityID,
            certificateSHA256: profile.certificateSHA256, infoPlist: infoPlist, executable: executable,
            executableName: executableName, signingEntitlementsXML: entitlements, profile: profile, now: now)
    }

    static func executableName(infoPlist: Data, bundleIdentifier: String) throws -> String {
        guard !infoPlist.isEmpty, infoPlist.count <= 256 * 1024,
              let name = try dictionary(infoPlist)["CFBundleExecutable"] as? String else { throw NativeSigningAcceptanceError.invalidInput }
        try validateInfo(infoPlist, executableName: name, bundleIdentifier: bundleIdentifier)
        return name
    }

    static func validateInfo(_ data: Data, executableName: String, bundleIdentifier: String) throws {
        guard !data.isEmpty, data.count <= 256 * 1024,
              executableName.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$", options: .regularExpression) != nil,
              !executableName.contains(".."), executableName.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [UInt8(45), 46, 95].contains($0)
              }) else { throw NativeSigningAcceptanceError.invalidInput }
        let info = try dictionary(data)
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleExecutable"] as? String == executableName,
              info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"],
              info["NSExtension"] == nil, info["WKWatchKitApp"] == nil,
              info["WKApplication"] == nil else { throw NativeSigningAcceptanceError.invalidInput }
    }

    /// Original claims are untrusted inputs, not authority. Permit only the narrow
    /// main-app subset; rewrite identity/group/debug claims from authenticated
    /// profile constraints. Never copy foreign/wildcard/shared keychain grants.
    static func signingEntitlements(requestedXML: Data?, bundleIdentifier: String,
                                    applicationIdentifier: String, teamIdentifier: String) throws -> Data {
        guard NativeAccountProvisioningRequest.isBundleIdentifier(bundleIdentifier),
              teamIdentifier.utf8.count == 10, teamIdentifier.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              applicationIdentifier == teamIdentifier + "." + bundleIdentifier else { throw NativeSigningAcceptanceError.profileMismatch }
        let requested: [String: Any]
        if let data = requestedXML {
            guard !data.isEmpty, data.count <= 64 * 1024 else { throw NativeSigningAcceptanceError.unsupportedEntitlements }
            requested = try dictionary(data)
        } else { requested = [:] }
        let allowed: Set<String> = ["application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups", "get-task-allow", "beta-reports-active"]
        guard Set(requested.keys).isSubset(of: allowed) else { throw NativeSigningAcceptanceError.unsupportedEntitlements }
        var originalAppID: String?
        if let raw = requested["application-identifier"] {
            guard let value = raw as? String, value.utf8.count <= 266 else { throw NativeSigningAcceptanceError.unsupportedEntitlements }
            let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].utf8.count == 10, String(parts[0]).range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
                  String(parts[1]) == bundleIdentifier else { throw NativeSigningAcceptanceError.unsupportedEntitlements }
            originalAppID = value
        }
        if let raw = requested["com.apple.developer.team-identifier"] {
            guard let team = raw as? String, team.utf8.count == 10, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
                  originalAppID.map({ $0 == team + "." + bundleIdentifier }) ?? true else { throw NativeSigningAcceptanceError.unsupportedEntitlements }
        }
        if let raw = requested["keychain-access-groups"] {
            guard let groups = raw as? [String], let originalAppID, groups == [originalAppID] else { throw NativeSigningAcceptanceError.unsupportedEntitlements }
        }
        if let raw = requested["get-task-allow"], strictBoolean(raw) == nil { throw NativeSigningAcceptanceError.unsupportedEntitlements }
        if let raw = requested["beta-reports-active"], strictBoolean(raw) != false { throw NativeSigningAcceptanceError.unsupportedEntitlements }
        let output: [String: Any] = ["application-identifier": applicationIdentifier,
            "com.apple.developer.team-identifier": teamIdentifier, "keychain-access-groups": [applicationIdentifier], "get-task-allow": true]
        do { return try PropertyListSerialization.data(fromPropertyList: output, format: .xml, options: 0) }
        catch { throw NativeSigningAcceptanceError.unsupportedEntitlements }
    }
    // Shared internal bounded plist policy; callers must enforce their role size limits.
    static func dictionary(_ data: Data) throws -> [String: Any] {
        var parserData = data
        if !data.starts(with: Data("bplist00".utf8)) {
            guard var xml = String(data: data, encoding: .utf8),
                  xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw NativeSigningAcceptanceError.invalidInput }
            // Never let an untrusted external/internal DTD reach the OS parser.
            // Only the inert standard Apple plist declaration is recognized and
            // removed for policy parsing; source bytes stay unchanged in handoff.
            if let start = xml.range(of: "<!DOCTYPE", options: .caseInsensitive) {
                guard let end = xml[start.lowerBound...].firstIndex(of: ">") else { throw NativeSigningAcceptanceError.invalidInput }
                let range = start.lowerBound...end
                let declaration = xml[range].components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                guard declaration == "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" else { throw NativeSigningAcceptanceError.invalidInput }
                xml.removeSubrange(range)
                guard xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else { throw NativeSigningAcceptanceError.invalidInput }
                parserData = Data(xml.utf8)
            }
        }
        do {
            guard let value = try PropertyListSerialization.propertyList(from: parserData, options: [], format: nil) as? [String: Any] else { throw NativeSigningAcceptanceError.invalidInput }
            return value
        } catch { throw NativeSigningAcceptanceError.invalidInput }
    }
    private static func strictBoolean(_ raw: Any) -> Bool? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
}
