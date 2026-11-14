//
//  BatchCertChecker.swift
//  VexSign
//
//  Validates every certificate in the library in one pass and reports the result
//  as a table: expiry, revocation, PPQ/PPQLess and JIT capability per certificate.
//
//  Individual lookups run concurrently (bounded task group) while the CoreData
//  objects stay on the main actor — only immutable snapshots cross over, the same
//  split `CertificateDashboardViewModel` uses.
//

import Foundation
import SwiftUI
import NimbleExtensions

// MARK: - Result row

// MARK: - Snapshot

/// Everything the concurrent check needs, copied off the managed object.
struct CertCheckSnapshot: Sendable {
	let uuid: String
	let name: String
	let storedExpiry: Date?
	let isRevoked: Bool
	let isPPQLess: Bool
	let password: String
	let p12URL: URL?
	let profileURL: URL?
}

// MARK: - Checker

@MainActor
final class BatchCertChecker: ObservableObject {
	static let shared = BatchCertChecker()

	/// Days before expiry that count as "expiring soon".
	static let expiringSoonWindow = 7

	@Published private(set) var results: [CertCheckResult] = []
	@Published private(set) var isRunning = false
	@Published private(set) var checkedCount = 0
	@Published private(set) var totalCount = 0
	@Published private(set) var lastRun: Date?

	private init() {}

	var summary: (valid: Int, expiring: Int, expired: Int, revoked: Int) {
		(
			results.filter { $0.status == .valid }.count,
			results.filter { $0.status == .expiringSoon }.count,
			results.filter { $0.status == .expired }.count,
			results.filter { $0.status == .revoked }.count
		)
	}

	/// Certificates that are in date but whose revocation was not established.
	var notCheckedCount: Int {
		results.filter { $0.status == .notChecked }.count
	}

	/// Validates every certificate in the library.
	/// - Parameter online: also ask the responder for revocation (sends
	///   certificate identifiers off-device). Off by default.
	func checkAll(online: Bool = false) async {
		guard !isRunning else { return }

		let snapshots = _snapshots(from: Storage.shared.getAllCertificates())
		await check(snapshots, online: online)
	}

	/// Runs the check over pre-built snapshots. Exposed for tests and for callers
	/// that already hold the certificates (e.g. the signing sheet).
	func check(_ snapshots: [CertCheckSnapshot], online: Bool) async {
		guard !isRunning else { return }

		isRunning = true
		totalCount = snapshots.count
		checkedCount = 0
		defer {
			isRunning = false
			lastRun = Date()
		}

		guard !snapshots.isEmpty else {
			results = []
			return
		}

		let collected: [CertCheckResult] = await withTaskGroup(of: (Int, CertCheckResult).self) { group in
			var running = 0
			var next = 0
			var collected: [(Int, CertCheckResult)] = []

			func addTask(at index: Int) {
				let snapshot = snapshots[index]
				group.addTask {
					let result = await Self._check(snapshot, online: online)
					return (index, result)
				}
			}

			// Bound the fan-out: OCSP responders rate-limit, and every task reads
			// a multi-megabyte P12.
			while next < snapshots.count, running < 3 {
				addTask(at: next)
				next += 1
				running += 1
			}

			while let finished = await group.next() {
				collected.append(finished)
				running -= 1
				if next < snapshots.count {
					addTask(at: next)
					next += 1
					running += 1
				}
				await MainActor.run { self.checkedCount += 1 }
			}

			return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
		}

		results = collected
	}

	// MARK: Per-certificate

	nonisolated private static func _check(_ snapshot: CertCheckSnapshot, online: Bool) async -> CertCheckResult {
		guard let profileURL = snapshot.profileURL else {
			return CertCheckResult.make(
				id: snapshot.uuid,
				name: snapshot.name,
				teamID: "—",
				expiryDate: snapshot.storedExpiry,
				isRevoked: snapshot.isRevoked,
				isPPQLess: snapshot.isPPQLess,
				revocationKnown: snapshot.isRevoked,
				detail: String.localized("Provisioning profile is missing.")
			)
		}

		guard let p12URL = snapshot.p12URL else {
			return CertCheckResult.make(
				id: snapshot.uuid,
				name: snapshot.name,
				teamID: "—",
				expiryDate: snapshot.storedExpiry,
				isRevoked: snapshot.isRevoked,
				isPPQLess: snapshot.isPPQLess,
				revocationKnown: snapshot.isRevoked,
				detail: String.localized("Certificate file or password is missing.")
			)
		}

		do {
			let health = try await CertificateInspector.inspect(
				id: snapshot.uuid,
				name: snapshot.name,
				p12: p12URL,
				password: snapshot.password,
				profile: profileURL,
				online: online
			)

			return CertCheckResult.make(
				id: snapshot.uuid,
				name: health.name,
				teamID: health.teamID,
				// The certificate can run out before its profile; whichever ends first is when
				// signing stops, and it is the date the certificate list and Home report.
				expiryDate: health.certificateExpires.map { min($0, health.expires) } ?? health.expires,
				isRevoked: snapshot.isRevoked || health.revocation == .revoked,
				isPPQLess: snapshot.isPPQLess,
				revocationKnown: health.revocation != .unknown,
				detail: health.detail
			)
		} catch {
			return CertCheckResult.make(
				id: snapshot.uuid,
				name: snapshot.name,
				teamID: "—",
				expiryDate: snapshot.storedExpiry,
				isRevoked: snapshot.isRevoked,
				isPPQLess: snapshot.isPPQLess,
				revocationKnown: snapshot.isRevoked,
				detail: error.localizedDescription
			)
		}
	}

	// MARK: Snapshots

	private func _snapshots(from certificates: [CertificatePair]) -> [CertCheckSnapshot] {
		certificates.compactMap { cert in
			guard let uuid = cert.uuid else { return nil }

			let profile = Storage.shared.getProvisionFileDecoded(for: cert)
			let name = cert.nickname
				?? profile?.Name
				?? String.localized("Certificate")

			return CertCheckSnapshot(
				uuid: uuid,
				name: name,
				storedExpiry: cert.expiration,
				isRevoked: cert.revoked,
				isPPQLess: cert.isPPQLess,
				// Read on the main actor: the Keychain item may need a migration write.
				password: cert.signingPassword ?? "",
				p12URL: Storage.shared.getFile(.certificate, from: cert),
				profileURL: Storage.shared.getFile(.provision, from: cert)
			)
		}
	}
}
