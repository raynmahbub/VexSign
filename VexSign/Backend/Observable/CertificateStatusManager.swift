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
//  identifiers only (docs/ROADMAP.md). The cache below holds a status
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

	/// What the stored row says, used when no OCSP result exists yet.
	static func deviceStatus(for cert: CertificatePair) -> CertificateStatusValue {
		cert.revoked == true ? .revoked : .unknown
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

// MARK: - Snapshot

/// The cached result of one OCSP check.
struct CertificateRevocationSnapshot: Codable, Equatable {
	/// How long a verdict is trusted before it is fetched again.
	static let defaultMaxAge: TimeInterval = 30 * 60

	let status: CertificateStatusValue
	/// The inspector's explanation of how the verdict was reached.
	let detail: String
	let checkedAt: Date

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

	private static let storageKey = "VexSign.certificate.revocationSnapshots"
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

	func effectiveStatus(for cert: CertificatePair) -> CertificateStatusValue {
		guard let snapshot = revocationSnapshot(for: cert), snapshot.status != .unknown else {
			return CertificateStatusValue.deviceStatus(for: cert)
		}

		return snapshot.status
	}

	func effectiveStatusTitle(for cert: CertificatePair) -> String {
		guard let snapshot = revocationSnapshot(for: cert), snapshot.status != .unknown else {
			return CertificateStatusValue.deviceStatus(for: cert).title
		}

		return snapshot.displayTitle
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
			let uuid = cert.uuid,
			let p12URL = Storage.shared.getFile(.certificate, from: cert),
			let profileURL = Storage.shared.getFile(.provision, from: cert)
		else {
			return
		}

		guard !refreshingRevocationIDs.contains(uuid) else { return }
		guard force || _shouldRefresh(uuid) else { return }

		refreshingRevocationIDs.insert(uuid)

		let password = cert.signingPassword ?? ""
		let name = cert.nickname ?? String.localized("Certificate")

		Task {
			defer { refreshingRevocationIDs.remove(uuid) }

			guard let health = try? await CertificateInspector.inspect(
				id: uuid,
				name: name,
				p12: p12URL,
				password: password,
				profile: profileURL,
				online: true
			) else {
				return
			}

			revocationSnapshots[uuid] = CertificateRevocationSnapshot(
				status: CertificateStatusValue(revocation: health.revocation),
				detail: health.detail,
				checkedAt: health.checkedAt
			)
			_persist()
		}
	}

	/// Runs the stored-row revocation check and then the OCSP check.
	func refreshStatus(for cert: CertificatePair, forceRevocation: Bool = true) {
		guard let uuid = cert.uuid else { return }

		if !refreshingDeviceStatusIDs.contains(uuid) {
			refreshingDeviceStatusIDs.insert(uuid)

			Storage.shared.revokagedCertificate(for: cert) { _ in
				Task { @MainActor in
					self.refreshingDeviceStatusIDs.remove(uuid)
				}
			}
		}

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
