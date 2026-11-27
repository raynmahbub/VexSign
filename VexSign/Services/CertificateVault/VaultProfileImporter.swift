//
//  VaultProfileImporter.swift
//  VexSign
//
//  Converts an authenticated provisioning profile into a bounded, displayable
//  inventory record. Parsing is delegated to the existing CMS verifier: an XML
//  plist found in arbitrary bytes is never treated as a provisioned profile.
//

import Foundation

enum VaultProfileImporter {
    static func parse(_ data: Data, now: Date = Date(), importedAt: Date = Date()) throws -> VaultProfile {
        let profile: Certificate
        do {
            // Expiry is reported as a state, not treated as a parse failure, so
            // an expired profile can still be listed and explained.
            profile = try ProvisioningProfileParser.parse(data, now: now, allowingExpiredForDisplay: true)
        } catch {
            throw VaultError.invalidProfile
        }
        return map(profile, now: now, importedAt: importedAt)
    }

    static func map(
        _ profile: Certificate,
        now: Date = Date(),
        importedAt: Date = Date(),
        limitations: [String] = []
    ) -> VaultProfile {
        let grants = profile.Entitlements ?? [:]
        let appIdentifier = grants["application-identifier"]?.value as? String
        let team = profile.TeamIdentifier.first
        let type = profile.profileType

        var missing: [String] = []
        if appIdentifier == nil { missing.append("application identifier") }
        if team == nil { missing.append("team identifier") }
        if profile.UUID.isEmpty { missing.append("profile UUID") }
        if profile.Platform.isEmpty { missing.append("platform") }
        if (profile.DeveloperCertificates ?? []).isEmpty { missing.append("developer certificates") }
        if missing.isEmpty && UUID(uuidString: profile.UUID) == nil { missing.append("valid profile UUID") }

        let parseStatus: VaultProfileParseStatus = missing.isEmpty ? .parsed : .incomplete
        let validity: VaultProfileValidity
        if profile.ExpirationDate <= now {
            validity = .expired
        } else if profile.CreationDate > now {
            validity = .notYetValid
        } else {
            validity = .valid
        }

        return VaultProfile(
            id: VaultIdentifier.profileID(uuid: profile.UUID),
            uuid: profile.UUID,
            name: profile.Name,
            appIdentifier: appIdentifier,
            teamIdentifier: team,
            teamName: profile.TeamName.isEmpty ? nil : profile.TeamName,
            applicationIdentifierPrefixes: profile.ApplicationIdentifierPrefix ?? [],
            platforms: profile.Platform,
            creationDate: profile.CreationDate,
            expirationDate: profile.ExpirationDate,
            type: type.rawValue,
            distribution: type.rawValue,
            provisionsAllDevices: profile.ProvisionsAllDevices == true,
            provisionedDevices: profile.ProvisionedDevices ?? [],
            entitlements: grants.keys.sorted().map {
                VaultEntitlement(key: $0, value: render(grants[$0]?.value))
            },
            capabilities: capabilities(in: grants),
            certificateFingerprints: (profile.DeveloperCertificates ?? []).map(SigningIdentity.fingerprint(of:)),
            parseStatus: parseStatus,
            validity: validity,
            limitations: (missing.isEmpty ? [] : ["Missing or unreadable: " + missing.joined(separator: ", ")]) + limitations,
            importedAt: importedAt
        )
    }

    // MARK: Bounded rendering

    private static let maximumRenderedLength = 512

    static func render(_ value: Any?) -> String {
        guard let value else { return "unavailable" }
        let text = render(value, depth: 0)
        return text.count > maximumRenderedLength ? String(text.prefix(maximumRenderedLength)) + "…" : text
    }

    private static func render(_ value: Any, depth: Int) -> String {
        guard depth < 4 else { return "…" }
        switch value {
        case let string as String: return string
        case let bool as Bool: return bool ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        case is NSNull: return "none"
        case let array as [Any]:
            let shown = array.prefix(16).map { render($0, depth: depth + 1) }
            return array.count > 16 ? shown.joined(separator: ", ") + "… (more)" : shown.joined(separator: ", ")
        case let dictionary as [String: Any]:
            let shown = dictionary.keys.sorted().prefix(16).map { key in
                key + "=" + render(dictionary[key] as Any, depth: depth + 1)
            }
            return dictionary.count > 16 ? shown.joined(separator: "; ") + "; …" : shown.joined(separator: "; ")
        default: return String(describing: value)
        }
    }

    private static func capabilities(in grants: [String: AnyCodable]) -> [String] {
        let known = [
            "get-task-allow": "Debugging (get-task-allow)",
            "aps-environment": "Push notifications",
            "com.apple.developer.associated-domains": "Associated domains",
            "com.apple.developer.icloud-container-identifiers": "iCloud containers",
            "com.apple.developer.keychain-compartments": "Keychain sharing",
            "com.apple.developer.networking.apple-pay": "Apple Pay",
            "com.apple.developer.networking.wifi-info": "Wi-Fi information",
            "com.apple.developer.healthkit": "HealthKit",
            "com.apple.developer.homekit": "HomeKit",
            "com.apple.developer.siri": "Siri",
            "com.apple.security.application-groups": "App groups",
            "com.apple.developer.in-app-payments": "In-app payments"
        ]
        var result: [String] = []
        for key in grants.keys.sorted() {
            if let label = known[key] {
                result.append(label)
            } else if key.hasPrefix("com.apple.developer.") {
                result.append(String(key.dropFirst("com.apple.developer.".count)))
            }
        }
        return result
    }
}
