//
//  CertificateManagementService.swift
//  VexSign
//
//  Certificate import, PKCS#12 verification, pairing file validation/installation,
//  and controlled certificate export.
//

import Foundation
import Security
import UIKit
import Zsign
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
        Task.detached {
            let keyAccess = p12URL.startAccessingSecurityScopedResource()
            let provisionAccess = provisionURL.startAccessingSecurityScopedResource()
            defer {
                if keyAccess { p12URL.stopAccessingSecurityScopedResource() }
                if provisionAccess { provisionURL.stopAccessingSecurityScopedResource() }
            }
            let handler = CertificateFileHandler(
                key: p12URL,
                provision: provisionURL,
                password: p12Password,
                nickname: certificateName.isEmpty ? nil : certificateName,
                isDefault: isDefault
            )

            do {
                guard validateCertificatePassword(for: p12URL, with: p12Password, using: provisionURL) else {
                    throw CertificateFileHandlerError.invalidIdentity
                }
                try await handler.copy()
                try await handler.addToDatabase()
                await MainActor.run {
                    completion(nil)
                }
            } catch {
                handler.clean()
                await MainActor.run {
                    completion(error)
                }
            }
        }
    }

    static func validateCertificatePassword(
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

        // Security validates both the password and private key without the old
        // OpenSSL CMS warm-up, which asserted on malformed or unreadable profiles.
        guard CertificateReader(provision).decoded != nil,
              let data = try? CertificateInputReader.read(key), !data.isEmpty else { return false } // try? ok: validation check; unreadable key fails validation
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let identities = items as? [[String: Any]] else { return false }
        return identities.contains { $0[kSecImportItemIdentity as String] != nil }
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
                let certificateKeyFileData = try? Data(contentsOf: certificateKeyFile) // try? ok: certificate file may be missing or unreadable
            else {
                return
            }

            let base64encodedCert = certificateKeyFileData.base64EncodedString()

            var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
            allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")

            guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
                return
            }

            let urlStr = template
                .replacingOccurrences(of: "$(BASE64_CERT)", with: encodedCert)
                .replacingOccurrences(of: "$(PASSWORD)", with: certificate.signingPassword ?? "")

            guard let callbackUrl = URL(string: urlStr) else {
                return
            }

            // Reject web schemes and dangerous protocols to prevent private key exfiltration
            guard let scheme = callbackUrl.scheme?.lowercased(),
                  !["http", "https", "file", "javascript", "data", "about"].contains(scheme) else {
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
