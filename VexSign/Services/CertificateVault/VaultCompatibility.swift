//
//  VaultCompatibility.swift
//  VexSign
//
//  A pure, deterministic decision about one certificate/profile pair. It never
//  signs, never talks to Apple, and never guesses missing metadata. An absent
//  field produces `incomplete`; an unreadable app entitlement set produces
//  `requiresAdditionalValidation`, never `compatible`.
//

import Foundation

enum VaultCompatibility {
    static func evaluate(
        certificate: VaultCertificate?,
        profile: VaultProfile,
        target: VaultCompatibilityTarget,
        now: Date = Date()
    ) -> VaultAssociation {
        let make: (VaultAssociationOutcome, [String]) -> VaultAssociation = { outcome, reasons in
            VaultAssociation(
                certificateID: certificate?.id ?? VaultIdentifier.certificateID(fingerprint: "unknown"),
                profileID: profile.id,
                outcome: outcome,
                reasons: reasons,
                target: target,
                evaluatedAt: now
            )
        }

        guard profile.parseStatus != .invalid, !profile.uuid.isEmpty else {
            return make(.invalid, ["The profile could not be parsed as authenticated provisioning metadata."])
        }
        guard
            let certificate,
            let pattern = profile.appIdentifier, !pattern.isEmpty,
            let profileTeam = profile.teamIdentifier, !profileTeam.isEmpty,
            !profile.platforms.isEmpty
        else {
            return make(.incomplete, [
                "The profile or certificate is missing an app identifier, team, platform, or certificate metadata."
            ])
        }
        guard let bundle = target.bundleIdentifier, !bundle.isEmpty else {
            return make(.incomplete, ["No app bundle identifier is available for this comparison."])
        }

        var expired: [String] = []
        if profile.isExpired(at: now) {
            expired.append("The provisioning profile expired " + relativeDate(profile.expirationDate, now: now) + ".")
        }
        if certificate.isExpired(at: now) {
            expired.append("The certificate expired " + relativeDate(certificate.notAfter, now: now) + ".")
        }
        if !expired.isEmpty { return make(.expired, expired) }

        var unsupported: [String] = []
        if profile.type == "distribution" {
            unsupported.append("This is an App Store distribution profile; apps signed with it do not install directly on a device.")
        }
        let requestedPlatforms = Set(target.platforms.map { $0.lowercased() })
        let profilePlatforms = Set(profile.platforms.map { $0.lowercased() })
        if !requestedPlatforms.isEmpty, requestedPlatforms.isDisjoint(with: profilePlatforms) {
            unsupported.append("The profile does not support this app's platform.")
        }
        if !unsupported.isEmpty { return make(.unsupported, unsupported) }

        var reasons: [String] = []
        if let targetTeam = target.teamIdentifier, !targetTeam.isEmpty,
           !ProfileCompatibility.prefixBelongsToProfile(
               targetTeam,
               teamIdentifiers: [profileTeam],
               applicationIdentifierPrefixes: profile.applicationIdentifierPrefixes
           ) {
            reasons.append("The app expects team \(targetTeam), but the profile belongs to team \(profileTeam).")
        }
        if let certificateTeam = certificate.teamIdentifier, !certificateTeam.isEmpty,
           !ProfileCompatibility.prefixBelongsToProfile(
               certificateTeam,
               teamIdentifiers: [profileTeam],
               applicationIdentifierPrefixes: profile.applicationIdentifierPrefixes
           ) {
            reasons.append("The certificate belongs to team \(certificateTeam), but the profile belongs to team \(profileTeam).")
        }
        if !SignatureVerifier.coverage(of: pattern, includes: bundle) {
            reasons.append("The profile's App ID \(pattern) does not cover \(bundle).")
        }
        for nested in target.nestedBundleIdentifiers where !SignatureVerifier.coverage(of: pattern, includes: nested) {
            reasons.append("The profile does not cover the embedded bundle \(nested).")
        }
        if profile.certificateFingerprints.isEmpty {
            return make(.incomplete, ["The profile does not name any developer certificates, so authorization cannot be verified."])
        }
        if !profile.certificateFingerprints.contains(certificate.fingerprint.lowercased()) {
            reasons.append("The profile was issued for a different certificate than \(certificate.shortFingerprint).")
        }
        if let device = target.deviceIdentifier, !profile.provisionsAllDevices,
           !profile.provisionedDevices.isEmpty, !profile.provisionedDevices.contains(device) {
            reasons.append("The selected device is not in this profile's device list.")
        }

        let granted = Dictionary(uniqueKeysWithValues: profile.entitlements.map { ($0.key, $0.value) })
        var needsValidation = false
        if let requested = target.entitlements {
            for key in requested.keys.sorted() where !SignatureVerifier.tolerantEntitlementKeys.contains(key) {
                guard let value = granted[key] else {
                    reasons.append("The profile does not grant \(key).")
                    continue
                }
                if value != requested[key] {
                    reasons.append("The profile grants \(key) as \(value), which differs from the app's \(requested[key] ?? "unavailable").")
                }
            }
        } else {
            needsValidation = true
        }
        if target.requiresJIT && profile.type != "development" {
            needsValidation = true
            reasons.append("JIT requires a development profile and a debugger-attachable build; that cannot be confirmed from the profile alone.")
        }

        if !reasons.isEmpty { return make(.incompatible, reasons) }
        if needsValidation {
            reasons.append("The app's full entitlements were not available. Use the original signed build for final validation before installing.")
            return make(.requiresAdditionalValidation, reasons)
        }
        reasons.append(SignatureVerifier.isWildcard(pattern)
            ? "The profile covers this bundle through a wildcard App ID."
            : "The profile explicitly covers this bundle, team, certificate and requested entitlements.")
        return make(.compatible, reasons)
    }

    private static func relativeDate(_ date: Date?, now: Date) -> String {
        guard let date else { return "at an unknown time" }
        let days = Int((now.timeIntervalSince(date) / 86_400).rounded(.down))
        return days <= 0 ? "today" : "\(days) day(s) ago"
    }
}
