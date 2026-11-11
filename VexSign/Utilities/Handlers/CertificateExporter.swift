//
//  CertificateExporter.swift
//  VexSign
//
//  Bundles a certificate's p12 + mobileprovision + password into one zip, for the
//  in-app share sheet and the Web Manager download. Call on the main actor (reads CoreData).
//

import Foundation
import OSLog
import Zip

enum CertificateExporter {
	static func makeZip(for cert: CertificatePair) -> URL? {
		guard
			let p12 = Storage.shared.getFile(.certificate, from: cert),
			let provision = Storage.shared.getFile(.provision, from: cert)
		else { return nil }

        let name = cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? "Certificate"
        return packageWithPassword(p12: p12, provision: provision, name: name,
                                   directory: FileManager.default.uniqueTemporaryDirectory("CertExport"),
                                   password: { try cert.requireSigningPassword() })
    }

    /// Resolve the password before creating scratch files; an unavailable Keychain
    /// must fail closed, not produce an archive with a guessed or empty password.
    static func packageWithPassword(p12: URL, provision: URL, name: String, directory: URL,
                                    password: () throws -> String) -> URL? {
        do {
            let value = try password()
            return package(p12: p12, provision: provision, password: value, name: name, directory: directory)
        } catch {
            FileLogger.error("Certificate export password is unavailable.", category: "certificates")
            return nil
        }
    }

    /// `directory` must be a new scratch directory. A failed export removes only
    /// the directory it created, never an existing destination.
    static func package(p12: URL, provision: URL, password: String, name: String, directory dir: URL,
                        zip: ([URL], URL) throws -> Void = {
                            try Zip.zipFiles(paths: $0, zipFilePath: $1, password: nil, progress: nil)
                        }) -> URL? {
        let safe = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let fm = FileManager.default
        let zipURL = dir.appendingPathComponent("\(safe).zip")
        var created = false
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            created = true
            let inputs = [dir.appendingPathComponent("\(safe).p12"),
                          dir.appendingPathComponent("\(safe).mobileprovision"),
                          dir.appendingPathComponent("password.txt")]
            try fm.copyItem(at: p12, to: inputs[0])
            try fm.copyItem(at: provision, to: inputs[1])
            try Data(password.utf8).write(to: inputs[2])
            try zip(inputs, zipURL)
            // Do not leave unpacked private key or password beside the archive.
            for input in inputs { try fm.removeItem(at: input) }
            return zipURL
        } catch {
            if created {
                do { try fm.removeItem(at: dir) }
                catch { FileLogger.error("Could not remove failed certificate export: \(error.localizedDescription)", category: "certificates") }
            }
            return nil
        }
    }
}
