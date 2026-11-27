// MARK: - Unified identity compatibility
//
// Reuses the vault's deterministic certificate/profile evaluator. This file
// adds only the decisions the vault does not own: engine readiness, provider
// limitations, and explicit distribution-type restrictions read from the
// profile. It never signs and it never overstates an unknown field.

import Foundation

enum UnifiedIdentityCompatibility {
    struct Result: Equatable, Sendable {
        let outcome: VaultAssociationOutcome
        let reasons: [String]
        let profileID: String?
    }

    static func evaluate(
        identity: UnifiedSigningIdentity,
        profile: VaultProfile,
        target: VaultCompatibilityTarget,
        now: Date = Date()
    ) -> Result {
        var reasons: [String] = []
        guard identity.engineReady else {
            return Result(outcome: .incomplete, reasons: [
                "This identity cannot be used by the native signing engine. Import the original PKCS#12 and profile into the signing store."
            ], profileID: profile.id)
        }
        guard identity.canStartNativeSigning else {
            return Result(outcome: identity.validityState == .revoked ? .invalid : .expired,
                          reasons: ["The selected identity is \(identity.validityState.displayName.lowercased()); no signing was started."],
                          profileID: profile.id)
        }

        // Distribution restrictions are read from the profile, not from a name.
        switch UnifiedIdentityCatalog.profileClass(from: profile) {
        case .enterprise:
            return Result(outcome: .unsupported, reasons: [
                "This is an enterprise distribution profile. It is not a normal paid personal signing identity and cannot be used for ordinary device installation here."
            ], profileID: profile.id)
        case .distribution:
            if target.deviceIdentifier != nil {
                return Result(outcome: .unsupported, reasons: [
                    "An App Store distribution profile does not authorize direct installation on a device."
                ], profileID: profile.id)
            }
        case .adHoc, .development, .unknown:
            break
        }

        let vaultCertificate = VaultCertificate(
            id: identity.id,
            fingerprint: identity.fingerprint ?? "",
            displayName: identity.displayName,
            commonName: nil,
            issuerCommonName: nil,
            teamIdentifier: identity.teamIdentifier,
            serialNumber: nil,
            notBefore: identity.notBefore,
            notAfter: identity.notAfter,
            keyAlgorithm: nil,
            keySizeBits: nil,
            importedAt: now,
            keyState: identity.privateKeyAvailable ? .accessible : .missing
        )
        let association = VaultCompatibility.evaluate(
            certificate: identity.fingerprint == nil ? nil : vaultCertificate,
            profile: profile,
            target: target,
            now: now
        )
        reasons.append(contentsOf: association.reasons)

        if identity.providerID == .communityNexCerts {
            reasons.append("Shared community identity: the provider publishes the certificate and password together. Treat the resulting signature as untrusted.")
        }
        if identity.source == .appleFreeAccount || identity.source == .appleAccount {
            reasons.append("Free Personal Team profiles expire after about seven days and require attended renewal.")
        }

        let outcome: VaultAssociationOutcome
        if association.outcome == .compatible, identity.fingerprint == nil {
            // Without the certificate fingerprint the profile's authorization
            // list cannot be checked. Do not call that pair compatible.
            outcome = .requiresAdditionalValidation
            reasons.append("The certificate fingerprint was not available; profile authorization could not be proven.")
        } else {
            outcome = association.outcome
        }
        return Result(outcome: outcome, reasons: reasons, profileID: profile.id)
    }
}
