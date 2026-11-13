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
import SwiftUI
import NimbleExtensions

// MARK: - Status value

enum CertificateStatusValue: String, Codable {
	case signed
	case revoked
	case unknown

	/// Maps an on-device OCSP result onto the badge vocabulary.
	///
	/// Only positive evidence becomes `signed`. An unanswered query, an offline
	/// device or an unparsable response stays `unknown` — never "good", because a
	/// certificate shown as valid when its status is unknown is worse than an
	/// honest question mark.
	init(revocation: CertificateHealth.Revocation) {
		switch revocation {
		case .good: self = .signed
		case .revoked: self = .revoked
		case .unknown: self = .unknown
		}
	}

	var title: String {
		switch self {
		case .signed:
			String.localized("Signed")
		case .revoked:
			String.localized("Revoked")
		case .unknown:
			String.localized("Unknown")
		}
	}

	var icon: String {
		switch self {
		case .signed:
			"checkmark.seal"
		case .revoked:
			"xmark.octagon"
		case .unknown:
			"questionmark.circle"
		}
	}

	var color: Color {
		switch self {
		case .signed:
			.green
		case .revoked:
			.red
		case .unknown:
			.secondary
		}
	}
}

// MARK: - Status colour

extension CertificateStatus {
	var color: Color {
		switch self {
		case .valid: .green
		case .expired, .revoked: .red
		case .networkUnavailable: .orange
		case .unknown, .unsupported: .secondary
		}
	}
}

// MARK: - Snapshot

/// The cached result of one OCSP check.
struct CertificateRevocationSnapshot: Codable, Equatable {
	/// How long a verdict is trusted before it is fetched again.
	static let defaultMaxAge: TimeInterval = 30 * 60

	/// Why a check produced no verdict, when the reason is known. Stored beside the
	/// verdict so "the responder did not answer" is not flattened into plain `unknown`.
	enum Gap: String, Codable, Sendable {
		case responderUnreachable
		case unsupported
	}

	let status: CertificateStatusValue
	/// The inspector's explanation of how the verdict was reached.
	let detail: String
	let checkedAt: Date
	/// Absent for a verdict, and in snapshots written before the reason was recorded.
	let gap: Gap?
	/// The signing certificate's own end date, which can fall before the profile's. A
	/// date only: nothing here can reconstruct the certificate.
	let certificateExpires: Date?

	init(
		status: CertificateStatusValue,
		detail: String,
		checkedAt: Date,
		gap: Gap? = nil,
		certificateExpires: Date? = nil
	) {
		self.status = status
		self.detail = detail
		self.checkedAt = checkedAt
		self.gap = gap
		self.certificateExpires = certificateExpires
	}

	init(health: CertificateHealth) {
		let gap: Gap?
		switch health.revocationEvidence {
		case .responderUnreachable: gap = .responderUnreachable
		case .unsupported: gap = .unsupported
		case .good, .revoked, .notChecked, .inconclusive: gap = nil
		}
		self.init(
			status: CertificateStatusValue(revocation: health.revocation),
			detail: health.detail,
			checkedAt: health.checkedAt,
			gap: gap,
			certificateExpires: health.certificateExpires
		)
	}

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

	/// The stored verdict as evidence for `CertificateStatusAssessment`.
	var evidence: CertificateRevocationEvidence {
		switch status {
		case .signed: return .good(checkedAt: checkedAt)
		case .revoked: return .revoked
		case .unknown:
			switch gap {
			case .responderUnreachable: return .responderUnreachable
			case .unsupported: return .unsupported
			case nil: return .inconclusive
			}
		}
	}

	/// The cache rule, split out so it can be unit tested without a server or a
	/// certificate.
	func isFresh(now: Date = Date(), maxAge: TimeInterval = CertificateRevocationSnapshot.defaultMaxAge) -> Bool {
		abs(now.timeIntervalSince(checkedAt)) <= maxAge
	}

	/// Short label for a badge. `detail` is a sentence and would not fit.
	var displayTitle: String {
		switch status {
		case .signed: String.localized("OCSP Verified")
		case .revoked: String.localized("Revoked")
		case .unknown: String.localized("Unknown")
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
	func refreshRevocation(for cert: CertificatePair, force: Bool = true) {
		guard
            !cert.isDeleted, cert.managedObjectContext != nil,
			let uuid = cert.uuid,
			let p12URL = Storage.shared.getFile(.certificate, from: cert),
			let profileURL = Storage.shared.getFile(.provision, from: cert)
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

		Task {
			defer { refreshingRevocationIDs.remove(uuid) }

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

            guard !cert.isDeleted, cert.managedObjectContext != nil else { return }
            if health.revocation == .revoked {
                cert.revoked = true
                Storage.shared.saveContext()
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
