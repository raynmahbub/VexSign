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
import UserNotifications
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

		let settings = await UNUserNotificationCenter.current().notificationSettings()
		guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

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
			           days: certificate.days, warning: certificate.warning, level: level)
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
		let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
		return requests.filter { $0.identifier.hasPrefix("cert-") }.count
	}

	private static func post(uuid: String, nickname: String?, days: Int,
	                         warning: ImportedCertificateWarning, level: Int) async {
		let content = UNMutableNotificationContent()
		let name = nickname ?? String.localized("Certificate")
		switch warning {
		case .revoked:
			content.title = String.localized("Certificate Revoked")
			content.body = String.localized("“%@” was revoked. Replace it; re-signing cannot repair a revocation.", arguments: name)
		case .expired:
			content.title = String.localized("Certificate Expired")
			content.body = String.localized("“%@” has expired. Renew it to keep signing.", arguments: name)
		default:
			content.title = String.localized("Certificate Expiring")
			content.body = String.localized("“%@” expires in %lld day(s).", arguments: name, days)
		}
		content.sound = .default

		let request = UNNotificationRequest(identifier: "cert-\(uuid)-\(level)", content: content, trigger: nil)
		try? await UNUserNotificationCenter.current().add(request)
	}
}
