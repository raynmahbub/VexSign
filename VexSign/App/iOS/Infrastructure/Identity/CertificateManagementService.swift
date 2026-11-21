//
//  CertificateManagementService.swift
//  VexSign
//
//  Certificate import, PKCS#12 verification, pairing file validation/installation,
//  and controlled certificate export.
//

import Foundation
import UIKit
import NimbleJSON
import AltSourceKit
import IDeviceSwift
import OSLog
import NimbleExtensions

enum CertificateManagementService {
    static func importCertificateFiles(
        p12URL: URL,
        provisionURL: URL,
        p12Password: String,
        certificateName: String = "",
        isDefault: Bool = false,
        completion: @escaping (Error?) -> Void
    ) {
        importCertificateFilesIdentified(p12URL: p12URL, provisionURL: provisionURL,
            p12Password: p12Password, certificateName: certificateName, isDefault: isDefault) { result in
                switch result {
                case .success: completion(nil)
                case .failure(let error): completion(error)
                }
            }
    }

    /// Same importer and persistence transaction as manual certificate import.
    /// Returns only the UUID of the row actually committed, never a store index,
    /// password, private-key path or a best-guess newest certificate.
    static func importCertificateFilesIdentified(
        p12URL: URL, provisionURL: URL, p12Password: String,
        certificateName: String = "", isDefault: Bool = false,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // Start access before handing picker URLs to a detached worker. File-provider
        // scopes can expire while a queued task is waiting to begin; keep both scopes
        // open until the selected bytes have been staged and validated.
        let keyAccess = p12URL.startAccessingSecurityScopedResource()
        let provisionAccess = provisionURL.startAccessingSecurityScopedResource()
        Task.detached {
            defer {
                if keyAccess { p12URL.stopAccessingSecurityScopedResource() }
                if provisionAccess { provisionURL.stopAccessingSecurityScopedResource() }
            }
            // Read each selected file once into a size-bounded snapshot. Stage these exact bytes,
            // then authenticate and match the staged pair before committing its database row.
            let handler = CertificateFileHandler(
                password: p12Password,
                nickname: certificateName.isEmpty ? nil : certificateName,
                isDefault: isDefault
            )

            do {
                let p12Data = try CertificateInputReader.read(p12URL)
                let profileData = try CertificateInputReader.read(provisionURL)
                try await handler.stage(keyData: p12Data, provisionData: profileData)
                let stagedDirectory = FileManager.default.certificates(handler.certificateUUID)
                let stagedKey = stagedDirectory.appendingPathComponent(CertificateFileHandler.p12FileName)
                let stagedProfile = stagedDirectory.appendingPathComponent(CertificateFileHandler.profileFileName)
                guard validateSigningPair(for: stagedKey, with: p12Password, using: stagedProfile) else {
                    throw CertificateFileHandlerError.invalidIdentity
                }
                try await handler.addToDatabase()
                await MainActor.run {
                    completion(.success(handler.certificateUUID))
                }
            } catch {
                handler.clean()
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    static func validateSigningPair(
        for key: URL,
        with password: String,
        using provision: URL
    ) -> Bool {
        let keyAccess = key.startAccessingSecurityScopedResource()
        let provisionAccess = provision.startAccessingSecurityScopedResource()
        defer {
            if keyAccess { key.stopAccessingSecurityScopedResource() }
            if provisionAccess { provision.stopAccessingSecurityScopedResource() }
        }

        // Authenticate the profile, prove access to exactly one PKCS#12 private key,
        // and require its actual leaf certificate to be named by that profile before
        // this pair can be accepted for import or automatic enrollment.
        guard let profile = CertificateReader(provision).decoded,
              let data = try? CertificateInputReader.read(key), !data.isEmpty, // try? ok: unreadable input is an invalid pair
              let proof = try? SigningIdentityStore.inspect(data, password: password) else { return false } // try? ok: any password, format or key-proof failure rejects the pair
        return profileAuthorizes(proof.identity, profile: profile)
    }

    static func profileAuthorizes(_ identity: SigningIdentity, profile: Certificate) -> Bool {
        guard let certificates = profile.DeveloperCertificates, !certificates.isEmpty else { return false }
        return certificates.contains { SigningIdentity.fingerprint(of: $0) == identity.fingerprint }
    }

    /// The same bounded, format-aware parser is used by import, diagnostics and
    /// native connection. A recognized record is not evidence of device trust.
    @discardableResult
    static func validatePairingFile(_ data: Data) throws -> PairingRecordMetadata {
        try PairingRecordDocument.inspect(data)
    }

    @discardableResult
    static func installPairingFile(from url: URL, replacing expectedSHA256: String? = nil) async throws -> PairingRecordMetadata {
        // HeartbeatManager and PairingFileStorage remain the sole native/storage
        // owners. Import is serialized against use and requires reviewed replacement.
        let metadata = try await HeartbeatManager.shared.importPairingRecord(from: url, replacing: expectedSHA256)
        await MainActor.run { PairingBridge.invalidateSelectedDevice() }
        return metadata
    }

    static func exportCertificateAndOpenURL(using template: String) {
        func performExport(for certificate: CertificatePair) {
            guard
                let certificateKeyFile = Storage.shared.getFile(.certificate, from: certificate),
                // Bounded, and it refuses anything that is not a regular file. `Data(contentsOf:)`
                // had no ceiling, which mattered here more than elsewhere: `performExport` runs
                // inside a `UIAlertAction` handler, so the read, the base64 copy and the
                // percent-encoded copy all land on the main thread. Line 100 of this same file
                // already reads certificate material through `CertificateInputReader`.
                let certificateKeyFileData = try? CertificateInputReader.read(certificateKeyFile) // try? ok: certificate file may be missing, unreadable or oversized
            else {
                return
            }

            let base64encodedCert = certificateKeyFileData.base64EncodedString()

            var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
            allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")

            guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
                Logger.misc.error("Certificate export could not percent-encode the certificate payload")
                return
            }

            // The password is arbitrary user text, so it needs a stricter set than the base64
            // certificate above: `%` and `#` never occur in base64 but do occur in passwords, and
            // left raw one forms an invalid percent-escape and the other truncates the URL at the
            // fragment. Substituting it unencoded produced a callback that parsed to something
            // other than what was intended — or to nothing at all — so the export either failed
            // silently or handed the receiving app the wrong password.
            var allowedPasswordCharacters = CharacterSet.urlQueryAllowed
            allowedPasswordCharacters.remove(charactersIn: ";/?:@&=+$,%#[]!()'\"*")

            guard let encodedPassword = (certificate.signingPassword ?? "")
                .addingPercentEncoding(withAllowedCharacters: allowedPasswordCharacters) else {
                Logger.misc.error("Certificate export could not percent-encode the certificate password")
                return
            }

            let urlStr = template
                .replacingOccurrences(of: "$(BASE64_CERT)", with: encodedCert)
                .replacingOccurrences(of: "$(PASSWORD)", with: encodedPassword)

            guard let callbackUrl = URL(string: urlStr) else {
                Logger.misc.error("Certificate export produced an unparsable callback URL")
                return
            }

            // Reject web schemes and dangerous protocols to prevent private key exfiltration. The
            // deny-list is shared with `SecurityPolicyGateway`, which checks the template before
            // substitution; this re-checks the URL after it, so the two layers cannot disagree.
            guard let scheme = callbackUrl.scheme?.lowercased(),
                  !CertificateCallbackPolicy.disallowedSchemes.contains(scheme) else {
                Logger.misc.error("Rejected certificate export to web or unsafe URL scheme")
                return
            }

            UIApplication.shared.open(callbackUrl)
        }

        let certificates = Storage.shared.getAllCertificates()
        guard !certificates.isEmpty else { return }

        DispatchQueue.main.async {
            var selectionActions: [UIAlertAction] = []

            for cert in certificates {
                var title: String
                let decoded = Storage.shared.getProvisionFileDecoded(for: cert)

                title = cert.nickname ?? decoded?.Name ?? .localized("Unknown")

                if let getTaskAllow = decoded?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
                    title = "🐞 \(title)"
                }

                let selectAction = UIAlertAction(title: title, style: .default) { _ in
                    performExport(for: cert)
                }
                selectionActions.append(selectAction)
            }

            UIAlertController.showAlertWithCancel(
                title: .localized("Export Certificate"),
                message: .localized("Do you want to export your certificate to an external app? That app will be able to sign apps using your certificate."),
                style: .alert,
                actions: selectionActions
            )
        }
    }
}
