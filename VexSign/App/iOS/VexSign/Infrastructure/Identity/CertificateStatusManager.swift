//
//  CertificateStatusManager.swift
//  VexSign
//
//  Caches the on-device OCSP verdict for each certificate so the library can show
//  whether a certificate is still signing instead of waiting for an install to
//  fail.
//
//  There is no remote verdict service. A certificate's private key and its
//  password never leave the device: revocation evidence comes from
//  `CertificateInspector`, which asks the OCSP responder using certificate
//  identifiers only. The cache below holds a status
//  word, a sentence and a date — never key material.
//

import Foundation
import CoreData
import SwiftUI
import NimbleExtensions

// MARK: - Status value

extension CertificateRevocationSnapshot {
	/// Where the snapshots are persisted, keyed by certificate UUID.
	static let storageKey = "VexSign.certificate.revocationSnapshots"

	/// The persisted snapshot for one certificate, readable off the main actor. The signing
	/// run uses it to learn the certificate's own end date without touching the manager.
	static func stored(forCertificateUUID uuid: String, defaults: UserDefaults = .standard) -> CertificateRevocationSnapshot? {
		guard let data = defaults.data(forKey: storageKey) else { return nil }
		do {
			return try JSONDecoder().decode([String: CertificateRevocationSnapshot].self, from: data)[uuid]
		} catch {
			// An unreadable cache is no evidence; the status check rewrites it.
			return nil
		}
	}


}

// MARK: - Manager

@MainActor
final class CertificateStatusManager: ObservableObject {
	static let shared = CertificateStatusManager()

	@Published private(set) var revocationSnapshots: [String: CertificateRevocationSnapshot]
	@Published private(set) var refreshingRevocationIDs: Set<String> = []
	@Published private(set) var refreshingDeviceStatusIDs: Set<String> = []
    private var revocationJobs: [String: UUID] = [:]
    private var revocationTasks: [String: Task<Void, Never>] = [:]

	private static let storageKey = CertificateRevocationSnapshot.storageKey
	/// Written by the removed third-party checker. Deleted on launch and never
	/// read: those verdicts were produced from an uploaded p12, so they are not
	/// evidence this app can stand behind.
	private static let legacyStorageKey = "VexSign.certificate.appleStatusSnapshots"
	/// Consent switch for uploading private keys, from the same removed service.
	private static let legacyUploadKey = "VexSign.security.allowLegacyCertificateUpload"

	private init() {
		UserDefaults.standard.removeObject(forKey: Self.legacyStorageKey)
		UserDefaults.standard.removeObject(forKey: Self.legacyUploadKey)

		if
			let data = UserDefaults.standard.data(forKey: Self.storageKey),
			let snapshots = try? JSONDecoder().decode([String: CertificateRevocationSnapshot].self, from: data) {
			self.revocationSnapshots = snapshots
		} else {
			self.revocationSnapshots = [:]
		}
	}

	func revocationSnapshot(for cert: CertificatePair) -> CertificateRevocationSnapshot? {
		guard let uuid = cert.uuid else { return nil }
		return revocationSnapshots[uuid]
	}

	/// The one status a certificate is shown with.
	///
	/// It replaces reading the cached verdict directly, which showed a certificate as
	/// verified for as long as the cache entry existed — after it expired, and however long
	/// ago the check ran. The assessment weighs expiry, the stored revocation flag and the
	/// age of the evidence together; see `CertificateStatusAssessment`.
	func assessment(for cert: CertificatePair, now: Date = Date()) -> CertificateStatusAssessment {
		let snapshot = revocationSnapshot(for: cert)
		return CertificateStatusAssessment.assess(
			.init(
				certificateExpiry: snapshot?.certificateExpires,
				profileExpiry: cert.expiration,
				revokedOnRecord: cert.revoked == true,
				evidence: snapshot?.evidence ?? .notChecked
			),
			now: now
		)
	}

	func hasFreshStatus(for cert: CertificatePair) -> Bool {
		guard let uuid = cert.uuid else { return false }
		return !_shouldRefresh(uuid)
	}

	func isRefreshingRevocation(for cert: CertificatePair) -> Bool {
		guard let uuid = cert.uuid else { return false }
		return refreshingRevocationIDs.contains(uuid)
	}

	func isRefreshingDeviceStatus(for cert: CertificatePair) -> Bool {
		guard let uuid = cert.uuid else { return false }
		return refreshingDeviceStatusIDs.contains(uuid)
	}

	func refreshStatusIfNeeded(for cert: CertificatePair) {
		refreshRevocationIfNeeded(for: cert)
	}

	func refreshRevocationIfNeeded(for cert: CertificatePair) {
		guard let uuid = cert.uuid, _shouldRefresh(uuid) else { return }
		refreshRevocation(for: cert, force: false)
	}

	/// Asks the OCSP responder for this certificate's status. Sends certificate
	/// identifiers, never the p12 or its password.
	func refreshRevocation(for cert: CertificatePair, force: Bool = true, storage: Storage = .shared) {
		guard
            !cert.isDeleted, cert.managedObjectContext === storage.context, !cert.objectID.isTemporaryID,
			let uuid = cert.uuid,
			let p12URL = storage.getFile(.certificate, from: cert),
			let profileURL = storage.getFile(.provision, from: cert)
		else {
			return
		}

		guard !refreshingRevocationIDs.contains(uuid) else { return }
		guard force || _shouldRefresh(uuid) else { return }

		refreshingRevocationIDs.insert(uuid)

        guard let password = cert.signingPassword else {
            refreshingRevocationIDs.remove(uuid)
            return
        }
		let name = cert.nickname ?? String.localized("Certificate")

        let objectID = cert.objectID
        let generation = UUID()
        revocationJobs[uuid] = generation
        revocationTasks[uuid] = Task { @MainActor in
            defer {
                if revocationJobs[uuid] == generation {
                    revocationJobs.removeValue(forKey: uuid)
                    revocationTasks.removeValue(forKey: uuid)
                    refreshingRevocationIDs.remove(uuid)
                }
            }

			let health: CertificateHealth
			do {
				health = try await CertificateInspector.inspect(
					id: uuid,
					name: name,
					p12: p12URL,
					password: password,
					profile: profileURL,
					online: true
				)
			} catch {
				// The files could not be read, so nothing was learned. The previous snapshot
				// stays; its age is what keeps it from being shown as current.
				FileLogger.log("Certificate status check could not complete: \(error)", category: "certificate")
				return
			}

            guard !Task.isCancelled, revocationJobs[uuid] == generation else { return }
            let current: CertificatePair
            do {
                let request = CertificatePair.fetchRequest()
                request.predicate = NSPredicate(format: "SELF == %@", objectID)
                request.fetchLimit = 1
                guard let row = try storage.context.fetch(request).first, row === cert,
                      row.uuid == uuid, !row.isDeleted else { return }
                current = row
            } catch {
                FileLogger.error("Could not resolve the certificate after its status check.", category: "certificates")
                return
            }
            if health.revocation == .revoked {
                current.revoked = true
                storage.saveContext()
            }
			revocationSnapshots[uuid] = CertificateRevocationSnapshot(health: health)
			_persist()
		}
	}

    /// One system-trust check only; importing must not launch the unsafe native
    /// checker in parallel with CertificateInspector.
    func refreshStatus(for cert: CertificatePair, forceRevocation: Bool = true) {
        refreshRevocation(for: cert, force: forceRevocation)
    }

	func removeRevocationSnapshot(for cert: CertificatePair) {
        guard let uuid = cert.uuid else { return }
        removeRevocationSnapshot(certificateUUID: uuid)
    }

    func removeRevocationSnapshot(certificateUUID uuid: String) {
        revocationTasks.removeValue(forKey: uuid)?.cancel()
        revocationJobs.removeValue(forKey: uuid)
        revocationSnapshots.removeValue(forKey: uuid)
		refreshingRevocationIDs.remove(uuid)
		refreshingDeviceStatusIDs.remove(uuid)
		_persist()
	}

	private func _shouldRefresh(_ uuid: String) -> Bool {
		guard let snapshot = revocationSnapshots[uuid] else { return true }
		return !snapshot.isFresh()
	}

	private func _persist() {
		guard let data = try? JSONEncoder().encode(revocationSnapshots) else { return }
		UserDefaults.standard.set(data, forKey: Self.storageKey)
	}
}
