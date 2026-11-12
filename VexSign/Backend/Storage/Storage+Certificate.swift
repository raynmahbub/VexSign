//
//  Storage+Certificate.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 16.04.2025.
//

import CoreData
import OSLog

// MARK: - Class extension: certificate
extension Storage {
	@MainActor
	func addCertificate(
		uuid: String,
		password: String? = nil,
		nickname: String? = nil,
		ppq: Bool = false,
		expiration: Date,
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		StorageConcurrency.requireMainQueue()
		do {
			try SecureSecretStore.write(Data((password ?? "").utf8), account: "certificate.password.\(uuid)")
		} catch {
			completion(error)
			return
		}

		let new = CertificatePair(context: context)
		new.uuid = uuid
		new.date = Date()
		new.password = nil
		new.ppQCheck = ppq
		new.expiration = expiration
		new.nickname = nickname
		new.isDefault = isDefault
		new.revoked = false

		do {
			try context.save()
		} catch {
			context.delete(new)
			try? SecureSecretStore.delete("certificate.password.\(uuid)") // try? ok: best-effort cleanup on failed certificate creation
			completion(error)
			return
		}

        // Finish the import transaction/UI completion before any widget refresh.
        // Certificate changes do not require repository icon downloads.
        Task { @MainActor in
            await Task.yield()
            WidgetStatusPublisher.publish(includeRepository: false)
        }
		Haptics.lightImpact()
		Task { await AnalyticsStore.shared.record(.certificatesAdded) }
		completion(nil)
	}
	
    /// Removes the certificate row, its files and the secrets that belong to it.
    ///
    /// The Keychain is best-effort on purpose. It used to be a hard precondition — a throwing
    /// `SecItemDelete` returned early, so the row stayed in the list and tapping Delete did
    /// nothing at all, with nothing said about why. A locked keychain (or an item written by a
    /// build that stored it differently) must not be able to pin a certificate in the library;
    /// the secret is orphaned instead, and the account name is logged so it can be swept.
    func deleteCertificate(for cert: CertificatePair) {
        StorageConcurrency.requireMainQueue()
        if let uuid = cert.uuid {
            let account = "certificate.password.\(uuid)"
            do {
                try SecureSecretStore.delete(account)
            } catch {
                Logger.misc.error("Could not remove certificate Keychain item; cleanup will require an unlocked Keychain.")
            }
        }
		Task { @MainActor in
			CertificateStatusManager.shared.removeRevocationSnapshot(for: cert)
		}

		// The directory holds this certificate's `.p12` — its private key — and its profile,
		// so a failure here leaves usable key material on disk after the user asked for it to
		// be gone. The row is still deleted (a certificate that cannot be removed from the
		// list is worse), but the file error is reported rather than swallowed: the snapshot
		// of remaining files then names the orphan, and `Remove Leftovers` reclaims it.
		//
		// The default is to *not* sweep leftovers automatically, so silence here could leave
		// the key behind indefinitely.
		if let url = getUuidDirectory(for: cert) {
			do {
				if FileManager.default.fileExists(atPath: url.path) {
					try FileManager.default.removeItem(at: url)
				}
			} catch {
				Logger.misc.error(
					"Could not delete certificate files for \(cert.uuid ?? "an unnamed certificate"); the private key remains on disk until Remove Leftovers runs. \(LogRedaction.redact(error.localizedDescription), privacy: .public)"
				)
			}
		}
		context.delete(cert)
		saveContext()
		Task { @MainActor in WidgetStatusPublisher.publish() }
	}
	
	func getCertificate(for index: Int) -> CertificatePair? {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]

		let results = fetchOnQueue(fetchRequest)
		guard index >= 0 && index < results.count else {
			return nil
		}
		
		return results[index]
	}
	
    /// Compatibility entry point for certificate-list and auto-import callers.
    /// Never call Zsign.checkRevokage here: its native async OCSP implementation
    /// holds dangling certificate state and parses into an uninitialized pointer.
    @MainActor
    func revokagedCertificate(for cert: CertificatePair, completion: ((Bool) -> Void)? = nil) {
        guard !cert.isDeleted, cert.managedObjectContext != nil else {
            completion?(false)
            return
        }
        guard !cert.revoked else { completion?(true); return }
        guard let uuid = cert.uuid,
              let p12 = getFile(.certificate, from: cert),
              let profile = getFile(.provision, from: cert),
              let password = cert.signingPassword else {
            completion?(false)
            return
        }
        let name = cert.nickname ?? "Certificate"
        
        // Capture all needed data before the async work to avoid retaining the managed object
        let certUUID = uuid
        let certP12 = p12
        let certProfile = profile
        let certPassword = password
        let certName = name
        
        Task {
            do {
                let health = try await CertificateInspector.inspect(
                    id: certUUID, name: certName, p12: certP12, password: certPassword, profile: certProfile, online: true
                )
                // Re-fetch the certificate to ensure it still exists and is valid
                await MainActor.run {
                    guard let refreshedCert = self._certificate(uuid: certUUID),
                          !refreshedCert.isDeleted,
                          refreshedCert.managedObjectContext != nil else {
                        completion?(false)
                        return
                    }
                    if health.revocation == .revoked {
                        refreshedCert.revoked = true
                        self.saveContext()
                    }
                    completion?(refreshedCert.revoked)
                }
            } catch {
                // Offline, malformed or unverifiable evidence is unknown, not revoked.
                FileLogger.log("Certificate status check could not complete: \(error)", category: "certificate")
                await MainActor.run { completion?(false) }
            }
        }
    }
    
    @MainActor
    private func _certificate(uuid: String) -> CertificatePair? {
        let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "uuid == %@", uuid)
        fetchRequest.fetchLimit = 1
        return fetchOnQueue(fetchRequest).first
    }

	enum FileRequest: String {
		case certificate = "p12"
		case provision = "mobileprovision"
	}
	
	func getFile(_ type: FileRequest, from cert: CertificatePair) -> URL? {
		guard let url = getUuidDirectory(for: cert) else {
			return nil
		}
		
		return FileManager.default.getPath(in: url, for: type.rawValue)
	}
	
	func getProvisionFileDecoded(for cert: CertificatePair) -> Certificate? {
		guard let url = getFile(.provision, from: cert) else {
			return nil
		}
		
		let read = CertificateReader(url)
		return read.decoded
	}
	
	func getUuidDirectory(for cert: CertificatePair) -> URL? {
		guard let uuid = cert.uuid else {
			return nil
		}
		
		return FileManager.default.certificates(uuid)
	}
	
	func getAllCertificates() -> [CertificatePair] {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
		return fetchOnQueue(fetchRequest)
	}
}
