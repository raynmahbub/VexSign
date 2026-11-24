import Foundation
import CryptoKit
import Security
import Zsign

/// No XML substring search or raw-plist trust fallback. The CMS envelope (BER
/// or DER) is fully consumed and authenticated before any metadata is admitted.
/// DER-Encoded-Profile is retained as CMS-protected opaque data, not used as a
/// second, unauthenticated source of authority.
enum ProvisioningProfileParser {
    enum Failure: LocalizedError {
        case untrustedCMS, malformed, expired
        var errorDescription: String? {
            switch self {
            case .untrustedCMS: return "The provisioning profile is not an authenticated Apple CMS profile, or uses an unsupported signer/algorithm. Import the original Apple-issued file."
            case .malformed: return "The provisioning profile has malformed, inconsistent, or missing required metadata."
            case .expired: return "The provisioning profile is expired or not yet valid. Import a current profile."
            }
        }
    }

    static func parse(_ data: Data, now: Date = Date(), allowingExpiredForDisplay: Bool = false) throws -> Certificate {
        guard now.timeIntervalSince1970.isFinite, data.count <= CertificateInputReader.maximumBytes,
              let payload = VexVerifyProvisioningProfileCMS(data, now.timeIntervalSince1970) else { throw Failure.untrustedCMS }
        let profile: Certificate
        do { profile = try PropertyListDecoder().decode(Certificate.self, from: payload) }
        catch { throw Failure.malformed }
        try validateMetadata(profile, now: now, allowingExpiredForDisplay: allowingExpiredForDisplay)
        return profile
    }

    /// Schema/consistency seam only; successful metadata checks NEVER authenticate
    /// a caller-constructed model. Only parse() can produce admitted inventory.
    static func validateMetadata(_ profile: Certificate, now: Date, allowingExpiredForDisplay: Bool = false) throws {
        func appleIdentifier(_ value: String) -> Bool {
            value.utf8.count == 10 && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
        }
        let grants = profile.Entitlements?.mapValues(\.value) ?? [:]
        guard now.timeIntervalSince1970.isFinite,
              UUID(uuidString: profile.UUID) != nil, !profile.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.Name.utf8.count <= 1024, profile.TeamIdentifier.count == 1,
              profile.TeamIdentifier.allSatisfy(appleIdentifier),
              let prefixes = profile.ApplicationIdentifierPrefix, !prefixes.isEmpty,
              prefixes.count <= 16, Set(prefixes).count == prefixes.count, prefixes.allSatisfy(appleIdentifier),
              !profile.Platform.isEmpty, profile.Platform.count <= 16,
              Set(profile.Platform.map { $0.lowercased() }).count == profile.Platform.count,
              profile.Platform.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              let certificates = profile.DeveloperCertificates, (1...64).contains(certificates.count),
              Set(certificates).count == certificates.count,
              certificates.allSatisfy({ SigningIdentity($0) != nil && SecCertificateCreateWithData(nil, $0 as CFData) != nil }),
              ProfileEntitlementAuthorization.isBoundedPropertyList(grants),
              let appID = grants["application-identifier"] as? String,
              case .success(let authorized) = ProfileApplicationIdentifierMatcher.parse(appID),
              prefixes.contains(authorized.prefix),
              grants["com.apple.developer.team-identifier"] as? String == profile.TeamIdentifier[0],
              profile.CreationDate < profile.ExpirationDate,
              profile.CreationDate.timeIntervalSince1970.isFinite, profile.ExpirationDate.timeIntervalSince1970.isFinite else { throw Failure.malformed }
        if let devices = profile.ProvisionedDevices {
            guard devices.count <= 2048, Set(devices.map { $0.uppercased() }).count == devices.count,
                  devices.allSatisfy({ (8...80).contains($0.utf8.count) && $0.utf8.allSatisfy {
                      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 45
                  } }), !(profile.ProvisionsAllDevices == true && !devices.isEmpty) else { throw Failure.malformed }
        }
        if !allowingExpiredForDisplay && (profile.ExpirationDate <= now || profile.CreationDate > now) { throw Failure.expired }
    }

    /// Run-scoped, content-addressed cache. Re-read/hash on every access, so a
    /// replaced file never inherits old trust; check the validity window on hits.
    struct Cache {
        private var profiles: [String: Certificate] = [:]
        mutating func read(_ url: URL, now: Date = Date()) throws -> Certificate {
            let data = try CertificateInputReader.read(url)
            let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let cached = profiles[key] {
                guard cached.ExpirationDate > now, cached.CreationDate <= now else { throw Failure.expired }
                return cached
            }
            let profile = try parse(data, now: now)
            guard profiles.count < 512 else { throw SigningIdentityStore.InspectionFailure.inventoryLimit }
            profiles[key] = profile
            return profile
        }
    }
}
