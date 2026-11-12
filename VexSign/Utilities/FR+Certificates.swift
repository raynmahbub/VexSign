//
//  FR+Certificates.swift
//  VexSign
//
//  Certificate and pairing file handling.
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

extension FR {
    static func handleCertificateFiles(
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
                guard checkPasswordForCertificate(for: p12URL, with: p12Password, using: provisionURL) else {
                    throw CertificateFileHandlerError.invalidIdentity
                }
                try await handler.copy()
                try await handler.addToDatabase()
                await MainActor.run {
                    completion(nil)
                }
            } error {
                handler.clean()
                await MainActor.run {
                    completion(error)
                }
            }
        }
    }
    
    static func checkPasswordForCertificate(
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
    
    /// Validate before replacing a working record. Parsing is not device authentication;
    /// the transport still has to verify this record belongs to the connected device.
    static func validatePairingFile(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024,
            let record = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let hostID = record["HostID"] as? String,
            !hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "PairingImport", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String.localized("Invalid pairing file. Import a pairing plist containing a HostID from a trusted computer. The existing pairing file was not changed.")])
        }
    }

    static func movePairing(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2 * 1024 * 1024 else {
            throw NSError(domain: "PairingImport", code: 2, userInfo: [NSLocalizedDescriptionKey:
                String.localized("Pairing file is too large. The existing pairing file was not changed.")])
        }
        let data = try Data(contentsOf: url)
        try validatePairingFile(data)
        let dest = URL(fileURLWithPath: HeartbeatManager.pairingFile())
        // Atomic replacement leaves the previous record intact on write failure.
        try data.write(to: dest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        HeartbeatManager.shared.start(true)
    }
}