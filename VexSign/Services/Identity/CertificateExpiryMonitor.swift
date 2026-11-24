//
//  CertificateExpiryMonitor.swift
//  VexSign
//
//  Runs on launch while "Expiry Reminders" is enabled. Every imported certificate
//  is bucketed by how close it is to expiring (expired → 0 days → 3 → 7 → 14).
//  A local notification is posted the first time a certificate reaches a bucket,
//  and again only if it later drops into a more urgent one. State is persisted so
//  reminders never repeat for the same bucket.
//

import Foundation
import CoreData
import UserNotifications
import NimbleExtensions

enum CertificateExpiryMonitor {
	static let enabledKey = "VexSign.certificates.expiryRemindersEnabled"
	static let daysKey = "VexSign.certificates.expiryReminderDays"
	private static let statesKey = "VexSign.certificates.expiryReminderStates"

	/// Urgency buckets in days, most urgent first. Index == level.
	private static let buckets = [0, 3, 7, 14]

	private struct ExpiringCertificate {
		let uuid: String
		let nickname: String?
		let days: Int
	}

	static func checkOnLaunch() async {
		guard UserDefaults.standard.bool(forKey: enabledKey) else { return }

		let settings = await UNUserNotificationCenter.current().notificationSettings()
		guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

		let threshold = UserDefaults.standard.object(forKey: daysKey) as? Int ?? 14

		// Read everything on the view context's actor and hand back plain values —
		// managed objects must not be touched from the cooperative pool.
		let expiring: [ExpiringCertificate] = await MainActor.run {
			let pairs = (try? Storage.shared.context.fetch(CertificatePair.fetchRequest())) ?? []
			return pairs.compactMap { pair -> ExpiringCertificate? in
				guard let uuid = pair.uuid, let expiration = pair.expiration else { return nil }
				let days = Calendar.current.dateComponents([.day], from: Date(), to: expiration).day ?? 0
				guard days <= threshold else { return nil }
				return ExpiringCertificate(uuid: uuid, nickname: pair.nickname, days: days)
			}
		}

		var states = (UserDefaults.standard.dictionary(forKey: statesKey) as? [String: Int]) ?? [:]
		var didChange = false

		for certificate in expiring {
			let level = bucketLevel(for: certificate.days)
			if let notified = states[certificate.uuid], notified <= level { continue }

			await post(uuid: certificate.uuid, nickname: certificate.nickname, days: certificate.days, level: level)
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

	/// 0 = already expired, then days ≤ 3, ≤ 7, ≤ 14.
	private static func bucketLevel(for days: Int) -> Int {
		for (index, bucket) in buckets.enumerated() where days <= bucket {
			return index
		}
		return buckets.count - 1
	}

	private static func post(uuid: String, nickname: String?, days: Int, level: Int) async {
		let content = UNMutableNotificationContent()
		content.title = days < 0
			? String.localized("Certificate Expired")
			: String.localized("Certificate Expiring")
		content.body = days < 0
			? String.localized("“%@” has expired. Renew it to keep signing.", arguments: nickname ?? String.localized("Certificate"))
			: String.localized("“%@” expires in %lld day(s).", arguments: nickname ?? String.localized("Certificate"), days)
		content.sound = .default

		let request = UNNotificationRequest(identifier: "cert-\(uuid)-\(level)", content: content, trigger: nil)
		try? await UNUserNotificationCenter.current().add(request)
	}
}
