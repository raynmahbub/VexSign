//
//  CertificateExpiryMonitor.swift
//  VexSign
//
//  Runs on launch while "Expiry Reminders" is enabled. Imported certificates are
//  warned about at their actual expiry, or immediately on revocation; there is no
//  weekly refresh job for them. A reminder is posted the first time a certificate
//  reaches a warning level, and again only if it later becomes more urgent.
//

import Foundation
import CoreData
import NimbleExtensions

enum CertificateExpiryMonitor {
	static let enabledKey = "VexSign.certificates.expiryRemindersEnabled"
	static let daysKey = "VexSign.certificates.expiryReminderDays"
	private static let statesKey = "VexSign.certificates.expiryReminderStates"

	private struct ExpiringCertificate {
		let uuid: String
		let nickname: String?
		let days: Int
		let warning: ImportedCertificateWarning
	}

	static func checkOnLaunch() async {
		guard UserDefaults.standard.bool(forKey: enabledKey) else { return }

		let authorization = await VexSignNotificationService.shared.currentAuthorization()
		guard VexSignNotificationService.allowsDelivery(authorization) else { return }

		let threshold = UserDefaults.standard.object(forKey: daysKey) as? Int ?? ImportedCertificateRefreshPolicy.noticeDays

		// Read everything on the view context's actor and hand back plain values —
		// managed objects must not be touched from the cooperative pool.
		let expiring: [ExpiringCertificate] = await MainActor.run {
			let pairs = (try? Storage.shared.context.fetch(CertificatePair.fetchRequest())) ?? []
			return pairs.compactMap { pair -> ExpiringCertificate? in
				guard let uuid = pair.uuid, let expiration = pair.expiration else { return nil }
				let days = Calendar.current.dateComponents([.day], from: Date(), to: expiration).day ?? 0
				let warning = ImportedCertificateRefreshPolicy.warning(
					daysRemaining: days, isRevoked: pair.revoked == true
				)
				guard warning.requiresAttention, days <= threshold || warning == .revoked else { return nil }
				return ExpiringCertificate(uuid: uuid, nickname: pair.nickname, days: days, warning: warning)
			}
		}

		var states = (UserDefaults.standard.dictionary(forKey: statesKey) as? [String: Int]) ?? [:]
		var didChange = false

		for certificate in expiring {
			let level = ImportedCertificateRefreshPolicy.notificationLevel(for: certificate.warning)
			if let notified = states[certificate.uuid], notified <= level { continue }

			await post(uuid: certificate.uuid, nickname: certificate.nickname,
			           warning: certificate.warning)
			states[certificate.uuid] = level
			didChange = true
		}

		if didChange {
			UserDefaults.standard.set(states, forKey: statesKey)
		}
	}

	/// Runs a check immediately and reports how many expiry reminders are pending —
	/// the "Check Now" button in Settings.
	@discardableResult
	static func checkNow() async -> Int {
		await checkOnLaunch()
		let service = VexSignNotificationService.shared
		let pending = await service.pendingIdentifiers()
		return pending.filter {
			$0.hasPrefix("cert-") || $0.hasPrefix(ExpiryReminderScheduler.prefix)
		}.count
	}

	private static func post(uuid: String, nickname: String?,
	                         warning: ImportedCertificateWarning) async {
		// Date warnings are owned by `ExpiryReminderScheduler`. This path is
		// reserved for a verified revocation, which is not a date and needs an
		// immediate, explicit warning.
		guard warning == .revoked else { return }
		let name = nickname ?? String.localized("Certificate")
		let note = VexSignNotification(
			identifier: "com.vexsign.expiry.revoked.\(VexSignNotificationService.digest(uuid))",
			topic: .certificateExpiry,
			title: String.localized("Certificate Revoked"),
			body: String.localized("“%@” was revoked. Replace it; re-signing cannot repair a revocation.", arguments: name),
			category: .expiry,
			details: [NotificationPayloadKey.route.rawValue: "certificates"],
			isTimeSensitive: true
		)
		await VexSignNotificationService.shared.post(note, dedupeContentKey: "revoked|\(uuid)")
	}
}
