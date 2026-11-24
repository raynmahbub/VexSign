import Foundation

struct CertificateCompatibilityDiagnostic: Identifiable, Equatable, Hashable, Sendable {
    enum Reason: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
        case certificateExpired = "certificate-expired"
        case certificateRevoked = "certificate-revoked"
        case privateKeyUnavailable = "private-key-unavailable"
        case wrongPrivateKeyPassword = "wrong-private-key-password"
        case provisioningProfileExpired = "provisioning-profile-expired"
        case bundleIdentifierNotCovered = "bundle-identifier-not-covered"
        case deviceNotIncludedInProfile = "device-not-included-in-profile"
        case entitlementNotAuthorized = "entitlement-not-authorized"
        case nestedExtensionNotCovered = "nested-extension-not-covered"
        case certificateProfileMismatch = "certificate-profile-mismatch"
        case unsupportedSigningCapability = "unsupported-signing-capability"
    }

    enum Severity: String, Codable, Equatable, Hashable, Sendable {
        case blocking
        case advisory
    }

    let reason: Reason
    let severity: Severity
    let componentPath: String?
    let title: String
    let explanation: String
    let remediation: String

    var id: String {
        "\(reason.rawValue)|\(componentPath ?? ".")|\(explanation)"
    }

    var logLine: String {
        let prefix = severity == .blocking ? "Compatibility" : "Compatibility advisory"
        let scope = componentPath.map { " [\($0)]" } ?? ""
        return "\(prefix) (\(reason.rawValue))\(scope): \(explanation)"
    }

    static func make(
        reason: Reason,
        severity: Severity = .blocking,
        componentPath: String? = nil,
        detail: String? = nil,
        remediation: String? = nil
    ) -> CertificateCompatibilityDiagnostic {
        let defaults = Self.defaults(for: reason)
        let explanation = (detail?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaults.explanation
        let resolvedRemediation = (remediation?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? defaults.remediation
        return CertificateCompatibilityDiagnostic(
            reason: reason,
            severity: severity,
            componentPath: componentPath,
            title: defaults.title,
            explanation: explanation,
            remediation: resolvedRemediation
        )
    }

    private static func defaults(for reason: Reason) -> (title: String, explanation: String, remediation: String) {
        switch reason {
        case .certificateExpired:
            return (
                "Certificate expired",
                "The signing certificate is past its validity period and iOS will refuse apps signed with it.",
                "Renew the certificate in Apple Developer and import the replacement .p12 and provisioning profile."
            )
        case .certificateRevoked:
            return (
                "Certificate revoked",
                "Apple has revoked this signing certificate, so applications signed with it cannot be verified.",
                "Issue a new signing certificate and matching provisioning profile, then import both into VexSign."
            )
        case .privateKeyUnavailable:
            return (
                "Private key unavailable",
                "The .p12 private key is missing, stripped, or currently inaccessible from Keychain.",
                "Unlock the device or re-export the certificate with its private key included in the .p12 file."
            )
        case .wrongPrivateKeyPassword:
            return (
                "Incorrect .p12 password",
                "The password provided could not decrypt the .p12 certificate archive.",
                "Re-enter the exact export password set when the .p12 file was created."
            )
        case .provisioningProfileExpired:
            return (
                "Provisioning profile expired",
                "The provisioning profile has expired and can no longer authorize signing or installation.",
                "Generate and import a renewed provisioning profile for this signing certificate."
            )
        case .bundleIdentifierNotCovered:
            return (
                "Bundle identifier not covered",
                "The application's bundle identifier does not match the App ID pattern in this provisioning profile.",
                "Select a provisioning profile covering this App ID or adjust the target bundle identifier."
            )
        case .deviceNotIncludedInProfile:
            return (
                "Device not included in profile",
                "This device's UDID is not provisioned in the selected development or ad-hoc profile.",
                "Register the device UDID in Apple Developer, regenerate the profile, and re-import it."
            )
        case .entitlementNotAuthorized:
            return (
                "Entitlement not authorized",
                "One or more required application entitlements are not granted by the provisioning profile.",
                "Use a provisioning profile with the required capabilities enabled or adjust requested entitlements."
            )
        case .nestedExtensionNotCovered:
            return (
                "Nested extension not covered",
                "An embedded extension, widget, App Clip, or Watch app is not covered by any compatible profile.",
                "Add a provisioning profile for the nested bundle or explicitly authorize optional extension removal."
            )
        case .certificateProfileMismatch:
            return (
                "Certificate and profile mismatch",
                "The selected signing certificate is not listed in the provisioning profile's DeveloperCertificates.",
                "Import and select a provisioning profile issued for the exact same signing certificate."
            )
        case .unsupportedSigningCapability:
            return (
                "Unsupported signing capability",
                "This bundle structure, executable slice, or signing mode is not supported for device signing.",
                "Use a decrypted arm64 iOS build and a supported signing certificate issued for iOS device signing."
            )
        }
    }
}

// MARK: - Domain Converters

extension ProfileCompatibility.Issue {
    var compatibilityDiagnostic: CertificateCompatibilityDiagnostic {
        let severity: CertificateCompatibilityDiagnostic.Severity = isBlocking ? .blocking : .advisory
        let reason: CertificateCompatibilityDiagnostic.Reason
        switch code {
        case .profileExpired:
            reason = .provisioningProfileExpired
        case .appIdentifierMismatch:
            reason = .bundleIdentifierNotCovered
        case .extensionNotCovered:
            reason = .nestedExtensionNotCovered
        case .entitlementNotGranted:
            reason = .entitlementNotAuthorized
        case .certificateNotInProfile, .teamMismatch, .profileMissing:
            reason = .certificateProfileMismatch
        case .deviceNotProvisioned:
            reason = .deviceNotIncludedInProfile
        }
        return CertificateCompatibilityDiagnostic.make(
            reason: reason,
            severity: severity,
            detail: detail
        )
    }
}

extension SigningCapability.Issue {
    var compatibilityDiagnostic: CertificateCompatibilityDiagnostic {
        let mappedSeverity: CertificateCompatibilityDiagnostic.Severity = severity == .blocking ? .blocking : .advisory
        let reason: CertificateCompatibilityDiagnostic.Reason
        switch code {
        case .certificateExpired, .certificateExpiringSoon:
            reason = .certificateExpired
        case .certificateRevoked:
            reason = .certificateRevoked
        case .certificateMissing, .certificatePasswordUnavailable:
            reason = .privateKeyUnavailable
        case .certificateNotInProfile, .teamMismatch, .signerMismatch, .profileMissing:
            reason = .certificateProfileMismatch
        case .profileExpired:
            reason = .provisioningProfileExpired
        case .appIdentifierMismatch, .bundleIdentifierMissing:
            reason = .bundleIdentifierNotCovered
        case .extensionNotCovered:
            reason = .nestedExtensionNotCovered
        case .entitlementNotGranted:
            reason = .entitlementNotAuthorized
        case .deviceNotProvisioned:
            reason = .deviceNotIncludedInProfile
        case .profileUnreadable, .infoPlistUnreadable, .executableUnavailable,
             .executableUnsupportedPlatform, .executableEncrypted, .executablePlatformUnknown,
             .minimumOSNewerThanDevice, .deploymentTargetMismatch, .storageInsufficient,
             .injectionProblem, .nestedComponentInvalid, .general:
            reason = .unsupportedSigningCapability
        }
        return CertificateCompatibilityDiagnostic.make(
            reason: reason,
            severity: mappedSeverity,
            detail: detail,
            remediation: remediation
        )
    }
}

extension SigningResolutionIssue {
    func compatibilityDiagnostic(componentPath: String? = nil) -> CertificateCompatibilityDiagnostic {
        let isNested = componentPath.map { !$0.isEmpty && $0 != "." } ?? false
        let reason: CertificateCompatibilityDiagnostic.Reason
        switch code {
        case .expiration:
            let lowered = detail.lowercased()
            reason = lowered.contains("certificate") ? .certificateExpired : .provisioningProfileExpired
        case .privateKey:
            let lowered = detail.lowercased()
            reason = lowered.contains("password") ? .wrongPrivateKeyPassword : .privateKeyUnavailable
        case .identifier, .prefix:
            reason = isNested ? .nestedExtensionNotCovered : .bundleIdentifierNotCovered
        case .device:
            reason = .deviceNotIncludedInProfile
        case .entitlement:
            reason = .entitlementNotAuthorized
        case .certificate, .team:
            reason = .certificateProfileMismatch
        case .noCandidate:
            reason = isNested ? .nestedExtensionNotCovered : .certificateProfileMismatch
        case .authenticity, .mode, .platform, .structure:
            reason = .unsupportedSigningCapability
        }
        return CertificateCompatibilityDiagnostic.make(
            reason: reason,
            componentPath: componentPath,
            detail: detail
        )
    }
}

extension SigningComponentResolution {
    var compatibilityDiagnostics: [CertificateCompatibilityDiagnostic] {
        issues.map { $0.compatibilityDiagnostic(componentPath: target.relativePath) }
    }
}

extension SigningResolution {
    var compatibilityDiagnostics: [CertificateCompatibilityDiagnostic] {
        components.flatMap(\.compatibilityDiagnostics)
    }
}
