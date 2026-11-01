//
//  Storage+Certificate.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 16.04.2025.
//

import CoreData
import ZsignSwift

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
			try? SecureSecretStore.delete("certificate.password.\(uuid)")
			completion(error)
			return
		}

		CertificateStatusManager.shared.refreshStatus(for: new)
		WidgetStatusPublisher.publish()
		Haptics.lightImpact()
		Task { await AnalyticsStore.shared.record(.certificatesAdded) }
		completion(nil)
	}
	
    func deleteCertificate(for cert: CertificatePair) {
        StorageConcurrency.requireMainQueue()
        if let uuid = cert.uuid {
            do { try SecureSecretStore.delete("certificate.password.\(uuid)") }
            catch { return } // Keep the entry so deletion can be retried after unlock.
        }
		Task { @MainActor in
			CertificateStatusManager.shared.removeRevocationSnapshot(for: cert)
		}

		if let url = getUuidDirectory(for: cert) {
			try? FileManager.default.removeItem(at: url)
		}
		context.delete(cert)
		saveContext()
		Task { @MainActor in WidgetStatusPublisher.publish() }
	}
	
	func getCertificate(for index: Int) -> CertificatePair? {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]

		guard
			let results = try? context.fetch(fetchRequest),
			index >= 0 && index < results.count
		else {
			return nil
		}
		
		return results[index]
	}
	
	func revokagedCertificate(for cert: CertificatePair, completion: ((Bool) -> Void)? = nil) {
		guard !cert.revoked else {
			completion?(true)
			return
		}
		
		Zsign.checkRevokage(
			provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
			p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
			p12Password: cert.signingPassword ?? ""
		) { (status, _, _) in
			DispatchQueue.main.async {
				if status == 1 {
					cert.revoked = true
					self.saveContext()
				}
				completion?(status == 1)
			}
		}
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
		return (try? context.fetch(fetchRequest)) ?? []
	}
}
