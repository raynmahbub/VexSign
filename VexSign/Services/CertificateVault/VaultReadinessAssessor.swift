//
//  VaultReadinessAssessor.swift
//  VexSign
//
//  Turns an existing, read-only IPA inspection plus the vault inventory into a
//  plain statement of signing readiness. This is an assessment boundary only:
//  no signing is performed and structural signature evidence is never described
//  as cryptographically verified.
//

import Foundation

enum VaultReadinessAssessor {
    static func target(for inspection: AppBundleInspection) -> VaultCompatibilityTarget {
        VaultCompatibilityTarget(
            bundleIdentifier: inspection.identity.bundleIdentifier,
            teamIdentifier: inspection.signature.profileTeamIdentifier,
            // The inspection records capabilities, not the signed entitlements
            // blob. Treating them as equivalent would be a fabricated check.
            entitlements: nil,
            platforms: inspection.platform.platformName.map { [$0] } ?? [],
            nestedBundleIdentifiers: inspection.nestedBundles.compactMap(\.bundleIdentifier),
            deviceIdentifier: nil,
            requiresJIT: inspection.integration.capabilities.contains { $0.lowercased().contains("jit") }
        )
    }

    static func assess(
        inspection: AppBundleInspection,
        certificates: [VaultCertificate],
        profiles: [VaultProfile],
        associations: [VaultAssociation] = [],
        now: Date = Date()
    ) -> VaultReadiness {
        let target = target(for: inspection)
        guard !certificates.isEmpty, !profiles.isEmpty else {
            return VaultReadiness(
                state: .unavailable,
                certificateID: nil,
                profileID: nil,
                explanation: ["Import at least one certificate and one provisioning profile before assessing an app."]
            )
        }

        // Avoid recalculating an identical pair when the stored association was
        // made against exactly this app description.
        var evaluations: [VaultAssociation] = []
        for certificate in certificates {
            for profile in profiles {
                if let stored = associations.first(where: {
                    $0.certificateID == certificate.id && $0.profileID == profile.id && $0.target == target
                }) {
                    evaluations.append(stored)
                } else {
                    evaluations.append(VaultCompatibility.evaluate(
                        certificate: certificate, profile: profile, target: target, now: now
                    ))
                }
            }
        }

        func ranked(_ outcome: VaultAssociationOutcome) -> [VaultAssociation] {
            evaluations.filter { $0.outcome == outcome }.sorted { lhs, rhs in
                let lhsEmbedded = profiles.first(where: { $0.id == lhs.profileID })?.uuid == inspection.signature.profileUUID
                let rhsEmbedded = profiles.first(where: { $0.id == rhs.profileID })?.uuid == inspection.signature.profileUUID
                return lhsEmbedded && !rhsEmbedded
            }
        }

        if let best = ranked(.compatible).first {
            return VaultReadiness(
                state: .ready,
                certificateID: best.certificateID,
                profileID: best.profileID,
                explanation: ["A vault certificate and profile are compatible with this app's inspected identifier and team."] + best.reasons
            )
        }
        if let needs = ranked(.requiresAdditionalValidation).first {
            return VaultReadiness(
                state: .requiresValidation,
                certificateID: needs.certificateID,
                profileID: needs.profileID,
                explanation: ["No pair is proven compatible."] + needs.reasons
            )
        }
        let blockers = evaluations.filter {
            [.incompatible, .expired, .unsupported, .invalid, .incomplete].contains($0.outcome)
        }
        if let first = blockers.first {
            let summary = blockers.prefix(4).map { association in
                let cert = certificates.first(where: { $0.id == association.certificateID })?.displayName ?? "a certificate"
                let profileName = profiles.first(where: { $0.id == association.profileID })?.name ?? "a profile"
                return "\(cert) + \(profileName) (\(association.outcome.rawValue)): \(association.reasons.first ?? "No reason recorded.")"
            }
            return VaultReadiness(
                state: .blocked,
                certificateID: first.certificateID,
                profileID: first.profileID,
                explanation: ["No vault pair can sign this app as inspected."] + summary
            )
        }
        return VaultReadiness(
            state: .unavailable,
            certificateID: nil,
            profileID: nil,
            explanation: ["The vault inventory could not be assessed against this app."]
        )
    }
}
