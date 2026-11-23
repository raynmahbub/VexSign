//
//  CertificateAutoImporter.swift
//  VexSign
//
//  Auto-imports bundled certificates with hash-based change detection
//

import Foundation
import SwiftUI
import UIKit
import OSLog
import CryptoKit
import CommonCrypto
import NimbleExtensions

class CertificateAutoImporter {
	static let shared = CertificateAutoImporter()

	private let _importLock = NSLock()
	private var _isImporting = false

	private init() {}

	private func _beginImportRun() -> Bool {
		_importLock.lock()
		defer { _importLock.unlock() }
		guard !_isImporting else { return false }
		_isImporting = true
		return true
	}

	private func _endImportRun() {
		_importLock.lock()
		_isImporting = false
		_importLock.unlock()
	}

	/// Import certificates from signing-assets folder using content-addressed SHA-256 change detection.
	///
	/// Developer convenience only: the folder holds `cert.p12`, `cert.mobileprovision` and
	/// `cert.txt` (the p12 password, in plaintext) and every folder is imported as the *default*
	/// identity. It is gitignored (`signing-assets/`) and
	/// `security-validation/test_signing_identity_policy.py` fails the build if the folder is added
	/// to `project.pbxproj`, because an archive that ships it ships a signing key with it.
	func importBundledCertificatesIfNeeded() {
		guard let signingAssetsURL = Bundle.main.url(forResource: "signing-assets", withExtension: nil)
		else {
			Logger.misc.info("No signing-assets folder found in bundle")
			return
		}
		guard _beginImportRun() else { return }

		// Off the main thread so app launch isn't blocked; sequential per folder so
		// "Distribution last" deterministically finishes last and becomes default.
		Task.detached(priority: .utility) { [weak self] in
			guard let self else { return }
			defer { self._endImportRun() }

			do {
				let folderContents = try FileManager.default.contentsOfDirectory(
					at: signingAssetsURL,
					includingPropertiesForKeys: nil,
					options: .skipsHiddenFiles
				)

				// Distribution last so it imports last and becomes the default.
				let sortedFolders = folderContents.sorted { url1, url2 in
					let name1 = url1.lastPathComponent.lowercased()
					let name2 = url2.lastPathComponent.lowercased()

					let isDistribution1 = name1.contains("distribution") || name1.contains("dist")
					let isDistribution2 = name2.contains("distribution") || name2.contains("dist")

					if isDistribution1 != isDistribution2 {
						return !isDistribution1
					}
					return name1 < name2
				}

				for folderURL in sortedFolders {
					guard folderURL.hasDirectoryPath else { continue }

					let certName = folderURL.lastPathComponent
					let hashKey = "VexSign.certHash.\(certName)"

					let p12Url = folderURL.appendingPathComponent("cert.p12")
					let provisionUrl = folderURL.appendingPathComponent("cert.mobileprovision")
					let passwordUrl = folderURL.appendingPathComponent("cert.txt")

					guard
						FileManager.default.fileExists(atPath: p12Url.path),
						FileManager.default.fileExists(atPath: provisionUrl.path),
						FileManager.default.fileExists(atPath: passwordUrl.path)
					else {
						Logger.misc.warning("Skipping \(certName): missing required files")
						continue
					}

					guard let password = try? String(contentsOf: passwordUrl, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { // try? ok: password file may be unreadable
						Logger.misc.warning("Skipping \(certName): failed to read password")
						continue
					}

					let storedHash = UserDefaults.standard.string(forKey: hashKey)
					let certHash = Self.calculateCertificateHash(p12: p12Url, provision: provisionUrl, password: password)

					if certHash == storedHash {
						Logger.misc.info("Skipping \(certName): already imported (hash match)")
						continue
					}

					guard CertificateManagementService.validateSigningPair(for: p12Url, with: password, using: provisionUrl) else {
						Logger.misc.warning("Skipping \(certName): invalid certificate or password")
						continue
					}

					var existingCertUUID: String?
					if storedHash != nil {
						Logger.misc.info("Hash changed for \(certName), updating existing certificate")
						existingCertUUID = await MainActor.run {
							Storage.shared.getAllCertificates().first(where: { $0.nickname == certName })?.uuid
						}
					}

					if let existingCertUUID {
						let updateError: Error? = await withCheckedContinuation { continuation in
							self.updateCertificate(
								certUUID: existingCertUUID,
								p12URL: p12Url,
								provisionURL: provisionUrl,
								password: password
							) { error in
								continuation.resume(returning: error)
							}
						}
						if let error = updateError {
							Logger.misc.error("Failed to update \(certName): \(error.localizedDescription)")
							await MainActor.run {
								let generator = UINotificationFeedbackGenerator()
								generator.notificationOccurred(.error)
								UIAlertController.showAlertWithOk(
									title: .localized("Certificate Update Failed"),
									message: error.localizedDescription
								)
							}
						} else {
							Logger.misc.info("Successfully updated certificate: \(certName)")
							UserDefaults.standard.set(certHash, forKey: hashKey)
							await MainActor.run {
								let generator = UINotificationFeedbackGenerator()
								generator.notificationOccurred(.success)
							}
						}
					} else {
						let importError: Error? = await withCheckedContinuation { continuation in
							CertificateManagementService.importCertificateFiles(
								p12URL: p12Url,
								provisionURL: provisionUrl,
								p12Password: password,
								certificateName: certName,
								isDefault: true
							) { error in
								continuation.resume(returning: error)
							}
						}
						if let error = importError {
							Logger.misc.error("Failed to import \(certName): \(error.localizedDescription)")
							await MainActor.run {
								let generator = UINotificationFeedbackGenerator()
								generator.notificationOccurred(.error)
								UIAlertController.showAlertWithOk(
									title: .localized("Certificate Import Failed"),
									message: error.localizedDescription
								)
							}
						} else {
							Logger.misc.info("Successfully imported certificate: \(certName)")
							UserDefaults.standard.set(certHash, forKey: hashKey)
							await MainActor.run {
								let generator = UINotificationFeedbackGenerator()
								generator.notificationOccurred(.success)
							}
						}
					}
				}
			} catch {
				Logger.misc.error("Failed to list signing-assets: \(error)")
			}
		}
	}

	/// Content-addressed SHA-256 over the actual `.p12` bytes, `.mobileprovision` bytes, and password.
	nonisolated static func calculateCertificateHash(p12: URL, provision: URL, password: String) -> String {
		var hasher = SHA256()
		if let p12Data = try? Data(contentsOf: p12) { // try? ok: unreadable file falls back to path marker below
			hasher.update(data: Data("p12:".utf8))
			hasher.update(data: p12Data)
		} else {
			hasher.update(data: Data("p12-missing:\(p12.lastPathComponent)".utf8))
		}
		hasher.update(data: Data([0]))
		if let provData = try? Data(contentsOf: provision) { // try? ok: unreadable file falls back to path marker below
			hasher.update(data: Data("prov:".utf8))
			hasher.update(data: provData)
		} else {
			hasher.update(data: Data("prov-missing:\(provision.lastPathComponent)".utf8))
		}
		hasher.update(data: Data([0]))
		hasher.update(data: Data("pwd:\(password)".utf8))
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}

	/// Reset all stored certificate hashes (useful for debugging or forcing re-import)
	func resetCertificateHashes() {
		let defaults = UserDefaults.standard
		let allKeys = defaults.dictionaryRepresentation().keys

		for key in allKeys where key.hasPrefix("VexSign.certHash.") {
			defaults.removeObject(forKey: key)
		}

		Logger.misc.info("Reset all certificate hashes")
	}

	/// Update an existing certificate without breaking relationships
	private func updateCertificate(
		certUUID: String,
		p12URL: URL,
		provisionURL: URL,
		password: String,
		completion: @escaping (Error?) -> Void
	) {
        Task { @MainActor in
            do {
                guard let cert = Storage.shared.getAllCertificates().first(where: { $0.uuid == certUUID }) else {
                    throw CertificateUpdateError.directoryNotFound
                }
                let reader = CertificateReader(provisionURL)
                guard let decoded = reader.decoded else { throw CertificateUpdateError.invalidCertificate }
                guard let directory = Storage.shared.getUuidDirectory(for: cert) else {
                    throw CertificateUpdateError.directoryNotFound
                }
                let p12Destination = Storage.shared.getFile(.certificate, from: cert) ?? directory.appendingPathComponent("cert.p12")
                let provisionDestination = Storage.shared.getFile(.provision, from: cert) ?? directory.appendingPathComponent("cert.mobileprovision")
                let previousPassword = try cert.requireSigningPassword()
                // Only Sendable values cross the worker boundary, never CertificatePair.
                let files = try await Task.detached {
                    (try Data(contentsOf: p12Destination), try Data(contentsOf: provisionDestination),
                     try Data(contentsOf: p12URL), try Data(contentsOf: provisionURL))
                }.value
                do {
                    try await Task.detached {
                        try files.2.write(to: p12Destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                        try files.3.write(to: provisionDestination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    }.value
                    try cert.setSigningPassword(password)
                    cert.ppQCheck = decoded.PPQCheck ?? false
                    cert.expiration = decoded.ExpirationDate
                    cert.revoked = false
                    cert.date = Date()
                    Storage.shared.saveContext()
                    Storage.shared.revokagedCertificate(for: cert)
                } catch {
                    try await Task.detached {
                        try files.0.write(to: p12Destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                        try files.1.write(to: provisionDestination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    }.value
                    try cert.setSigningPassword(previousPassword)
                    throw error
                }
                completion(nil)
            } catch {
                completion(error)
            }
        }
	}
}

private enum CertificateUpdateError: Error {
	case invalidCertificate
	case directoryNotFound
}

// SHA256 extension for stable hashing
extension String {
	func sha256() -> String? {
		guard let data = self.data(using: .utf8) else { return nil }
		var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
		data.withUnsafeBytes {
			_ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
		}
		return hash.map { String(format: "%02x", $0) }.joined()
	}
}
