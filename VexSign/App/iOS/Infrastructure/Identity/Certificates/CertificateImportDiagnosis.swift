//
//  CertificateImportDiagnosis.swift
//  VexSign
//
//  The reasons a certificate pair can be rejected beyond the parser's own
//  vocabulary: an empty file, a profile that names no certificate, a `.p12` that
//  belongs to another identity, and an expired profile that was authenticated.
//
//  These exist so a failed import names one cause and one next step instead of
//  asking the user to re-check the password, which was usually not the problem.
//

import Foundation
import NimbleExtensions

enum CertificateImportDiagnosis: LocalizedError, Equatable {
    /// A `.p12` was chosen that holds only a certificate, or nothing at all.
    case emptyCertificateFile
    case profileListsNoCertificates
    /// The profile is valid but was issued for a different signing certificate.
    case identityNotInProfile(commonName: String?, profileName: String)
    case profileExpired(name: String, expiry: Date)
    /// The `.p12` opened, but its private key does not match its certificate.
    case keyDoesNotMatchCertificate(commonName: String?)

    var errorDescription: String? {
        switch self {
        case .emptyCertificateFile:
            return .localized("The selected .p12 file is empty. Choose the certificate file that was exported from Apple Developer, together with its password.")
        case .profileListsNoCertificates:
            return .localized("This provisioning profile does not name any signing certificate, so it cannot be paired with a .p12. Create a new profile in the Apple Developer portal and import it together with its certificate.")
        case .identityNotInProfile(let commonName, let profileName):
            // Naming the certificate is only possible when the name is known; the
            // sentence is written twice so neither branch formats a placeholder.
            guard let commonName, !commonName.isEmpty else {
                return .localized("The certificate in this .p12 is not one of the certificates in the provisioning profile “%@”. Import the .p12 and the profile that Apple issued for the same certificate.", arguments: profileName)
            }
            return .localized("The certificate “%@” is not one of the certificates in the provisioning profile “%@”. Import the .p12 and the profile that Apple issued for the same certificate.", arguments: commonName, profileName)
        case .profileExpired(let name, let expiry):
            let formatted = expiry.formatted(date: .abbreviated, time: .omitted)
            return .localized("The provisioning profile “%@” expired on %@. Import a current profile; the certificate can keep its existing private key.", arguments: name, formatted)
        case .keyDoesNotMatchCertificate(let commonName):
            guard let commonName, !commonName.isEmpty else {
                return .localized("The private key in this .p12 does not match its certificate. Export the identity again from Keychain Access and include both the certificate and its private key.")
            }
            return .localized("The private key in the .p12 does not match the certificate “%@”. Export the identity again from Keychain Access and include both the certificate and its private key.", arguments: commonName)
        }
    }

    var compatibilityDiagnostic: CertificateCompatibilityDiagnostic {
        let detail = errorDescription
        switch self {
        case .emptyCertificateFile, .keyDoesNotMatchCertificate:
            return CertificateCompatibilityDiagnostic.make(
                reason: .privateKeyUnavailable,
                detail: detail
            )
        case .profileListsNoCertificates, .identityNotInProfile:
            return CertificateCompatibilityDiagnostic.make(
                reason: .certificateProfileMismatch,
                detail: detail
            )
        case .profileExpired:
            return CertificateCompatibilityDiagnostic.make(
                reason: .provisioningProfileExpired,
                detail: detail
            )
        }
    }

    static func diagnostic(for error: Error) -> CertificateCompatibilityDiagnostic {
        if let diagnosis = error as? CertificateImportDiagnosis {
            return diagnosis.compatibilityDiagnostic
        }
        if let inspection = error as? SigningIdentityStore.InspectionFailure {
            switch inspection {
            case .wrongPassword:
                return CertificateCompatibilityDiagnostic.make(
                    reason: .wrongPrivateKeyPassword,
                    detail: inspection.errorDescription
                )
            case .certificateMissing, .privateKeyMissing, .inaccessible:
                return CertificateCompatibilityDiagnostic.make(
                    reason: .privateKeyUnavailable,
                    detail: inspection.errorDescription
                )
            case .multipleIdentities, .malformedPKCS12, .unsupportedKey, .inventoryLimit:
                return CertificateCompatibilityDiagnostic.make(
                    reason: .unsupportedSigningCapability,
                    detail: inspection.errorDescription
                )
            }
        }
        if let profileFailure = error as? ProvisioningProfileParser.Failure {
            switch profileFailure {
            case .expired:
                return CertificateCompatibilityDiagnostic.make(
                    reason: .provisioningProfileExpired,
                    detail: profileFailure.errorDescription
                )
            case .malformed, .untrustedCMS:
                return CertificateCompatibilityDiagnostic.make(
                    reason: .unsupportedSigningCapability,
                    detail: profileFailure.errorDescription
                )
            }
        }
        return CertificateCompatibilityDiagnostic.make(
            reason: .unsupportedSigningCapability,
            detail: LogRedaction.redact(error.localizedDescription)
        )
    }
}
