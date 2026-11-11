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
        // `requireSigningPassword` reads the Keychain-backed secret store, so it can throw. An
        // export that cannot produce the password is not a partial export — the zip would be
        // useless to whoever received it — so it returns nil like the missing-file cases above
        // rather than writing an archive that silently fails to unlock.
        let password: String
        do {
            password = try cert.requireSigningPassword()
        } catch {
            Logger.misc.error("Certificate export failed: no signing password available: \(error.localizedDescription)")
            return nil
        }
        return package(p12: p12, provision: provision, password: password, name: name,
                       directory: FileManager.default.uniqueTemporaryDirectory("CertExport"))
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
