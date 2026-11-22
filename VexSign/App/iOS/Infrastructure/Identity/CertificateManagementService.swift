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
                // `validateSigningPair` stays the single accept/reject decision. The
                // diagnosis only runs after a rejection, to say which of its causes it
                // was; a `nil` diagnosis still refuses the pair.
                guard validateSigningPair(for: stagedKey, with: p12Password, using: stagedProfile) else {
                    throw signingPairDiagnosis(for: stagedKey, with: p12Password, using: stagedProfile)
                        ?? CertificateFileHandlerError.invalidIdentity
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

    /// Imports from whatever the user actually chose: a `.p12` and a profile, or a
    /// single `.zip`/folder that holds both. Existing single-file imports keep
    /// working through the same staging and validation path; the bundle is only a
    /// way of finding the two files.
    static func importCertificateBundle(
        _ url: URL,
        p12Password: String,
        certificateName: String = "",
        isDefault: Bool = false,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let access = url.startAccessingSecurityScopedResource()
        Task.detached {
            let resolved: CertificateImportBundle.Resolved
            do {
                resolved = try CertificateImportBundle.resolve(url)
            } catch {
                if access { url.stopAccessingSecurityScopedResource() }
                await MainActor.run { completion(.failure(error)) }
                return
            }
            if let missing = CertificateImportBundle.missingRole(resolved) {
                if let staging = resolved.staging { try? FileManager.default.removeItem(at: staging) } // try? ok: rejected bundle leaves no temporary directory
                if access { url.stopAccessingSecurityScopedResource() }
                await MainActor.run { completion(.failure(missing)) }
                return
            }
            // The extracted copies must outlive the import that reads them, so the
            // staging directory is removed when that import reports back — never
            // when this wrapper returns.
            let staging = resolved.staging
            importCertificateFilesIdentified(
                p12URL: resolved.key,
                provisionURL: resolved.profile,
                p12Password: p12Password,
                certificateName: certificateName,
                isDefault: isDefault
            ) { result in
                if let staging { try? FileManager.default.removeItem(at: staging) } // try? ok: import finished; staging is disposable
                completion(result)
            }
            // The importer above opened its own scope on both files before this line.
            if access { url.stopAccessingSecurityScopedResource() }
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

    /// Explains why a pair was rejected instead of telling the user to check the password.
    ///
    /// Import used to collapse every outcome into one sentence naming the `.p12`, the
    /// profile and the password. The real causes differ and each needs a different
    /// action: an untrusted or non-Apple profile, an expired one, a profile that was
    /// issued for a different certificate, a wrong password, a `.p12` with no private
    /// key. The profile is re-read for display, so an expired one is reported as
    /// expired rather than as unreadable.
    static func signingPairDiagnosis(for key: URL, with password: String, using provision: URL) -> Error? {
        let profileData: Data
        do {
            profileData = try CertificateInputReader.read(provision)
        } catch {
            return error
        }
        let profile: Certificate
        do {
            profile = try ProvisioningProfileParser.parse(profileData, allowingExpiredForDisplay: true)
        } catch {
            return error
        }

        let keyData: Data
        do {
            keyData = try CertificateInputReader.read(key)
        } catch {
            return error
        }
        if keyData.isEmpty { return CertificateImportDiagnosis.emptyCertificateFile }

        let identity: SigningIdentity
        do {
            identity = try SigningIdentityStore.inspect(keyData, password: password).identity
        } catch {
            return error
        }

        guard let certificates = profile.DeveloperCertificates, !certificates.isEmpty else {
            return CertificateImportDiagnosis.profileListsNoCertificates
        }
        guard profileAuthorizes(identity, profile: profile) else {
            return CertificateImportDiagnosis.identityNotInProfile(
                commonName: identity.commonName,
                profileName: profile.Name
            )
        }
        // Authorized and parseable, so the only remaining question is the window: the
        // strict parser refuses an expired profile, and saying so is the difference
        // between "renew your profile" and "your password is wrong".
        if profile.ExpirationDate <= Date() || profile.CreationDate > Date() {
            return CertificateImportDiagnosis.profileExpired(
                name: profile.Name,
                expiry: profile.ExpirationDate
            )
        }
        return nil
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
            // Building one alert title per certificate used to call `getProvisionFileDecoded`
            // (a full, uncached CMS/DER parse of the provisioning profile) once per certificate,
            // all on the main thread — so the export sheet stalled in proportion to how many
            // certificates were installed. The cheap Core Data reads (nickname, profile path) stay
            // on the main queue and only Sendable values cross to a background queue for the
            // parses; the `CertificatePair` objects and `performExport` are touched on main alone.
            let inputs: [(nickname: String?, url: URL?)] = certificates.map { cert in
                (cert.nickname, Storage.shared.getFile(.provision, from: cert))
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let titles = inputs.map { input -> String in
                    let decoded = input.url.flatMap { CertificateReader($0).decoded }
                    var title = input.nickname ?? decoded?.Name ?? .localized("Unknown")
                    if let getTaskAllow = decoded?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
                        title = "🐞 \(title)"
                    }
                    return title
                }

                DispatchQueue.main.async {
                    let selectionActions = zip(certificates, titles).map { cert, title in
                        UIAlertAction(title: title, style: .default) { _ in
                            performExport(for: cert)
                        }
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
    }
}
