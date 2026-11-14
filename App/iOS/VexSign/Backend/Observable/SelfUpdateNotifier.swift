//
//  SelfUpdateNotifier.swift
//  VexSign
//
//  A local notification the first time VexSign sees a newer release than the one installed.
//
//  iOS gives an app no way to be told when a GitHub release is published: there is no push
//  infrastructure here and background work is scheduled by the system. So the notification is
//  posted by the update check VexSign already runs — at launch, from Update settings, or during a
//  scheduled automation pass.
//
//  Two rules keep it from being noise:
//   * once per version, however often the app checks;
//   * never in the foreground for a release the launch prompt is showing at that moment — the
//     prompt itself is the announcement. The version is remembered as "surfaced" instead, so if the
//     prompt is dismissed, the next check (a background automation pass, or a manual one) posts the
//     notification.
//
//  Everything that decides whether to post is pure, so it is tested without a device or a
//  notification centre.
//

import Foundation
import UIKit
import UserNotifications
import NimbleExtensions

enum SelfUpdateNotifier {
	/// Default on: a new release is the one piece of news the app can tell you about itself.
	static let enabledKey = "VexSign.selfUpdateNotifyEnabled"
	/// Versions already announced, newest last. Bounded so the key cannot grow forever.
	static let notifiedKey = "VexSign.selfUpdateNotifiedVersions"
	/// Versions the launch prompt already showed the user.
	static let surfacedKey = "VexSign.selfUpdateSurfacedVersions"
	/// Prefix for the request identifier, and for recognising our own notifications on tap.
	static let identifierPrefix = "vexsign.release."
	static let threadIdentifier = "vexsign.release"
	static let maximumRemembered = 20

	// MARK: - Preference

	static var isEnabled: Bool {
		get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
	}

	// MARK: - Decision

	/// Whether this release should be announced now.
	///
	/// - `authorization`: only `.authorized` and `.provisional` can deliver a notification.
	///   `.notDetermined` is deliberately not a reason to ask here — the permission is requested
	///   when the switch is turned on in Update settings, not from a background check.
	/// - `ignored`: a version the user chose to skip is not news.
	/// - `alreadyNotified`: one notification per version, however often the app checks.
	/// - `alreadySurfaced` + `isAppActive`: the launch prompt is already showing this release, so a
	///   banner on top of it would say the same thing twice.
	static func shouldNotify(
		version: String,
		isEnabled: Bool,
		authorization: UNAuthorizationStatus,
		alreadyNotified: Set<String>,
		ignored: Set<String>,
		alreadySurfaced: Set<String>,
		isAppActive: Bool
	) -> Bool {
		guard isEnabled else { return false }
		guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
		guard authorization == .authorized || authorization == .provisional else { return false }
		guard !alreadyNotified.contains(version) else { return false }
		guard !ignored.contains(version) else { return false }
		guard !(isAppActive && !alreadySurfaced.contains(version)) else { return false }
		return true
	}

	/// Appends a version to a remembered list, keeping the most recent `maximumRemembered`.
	static func remembering(_ version: String, in versions: [String]) -> [String] {
		var updated = versions.filter { $0 != version }
		updated.append(version)
		return Array(updated.suffix(maximumRemembered))
	}

	static func rememberedVersions() -> [String] {
		UserDefaults.standard.stringArray(forKey: notifiedKey) ?? []
	}

	static func surfacedVersions() -> [String] {
		UserDefaults.standard.stringArray(forKey: surfacedKey) ?? []
	}

	/// Called when the launch prompt presents a release, so a dismissed prompt can still be
	/// announced by a later check.
	static func noteSurfaced(_ version: String) {
		UserDefaults.standard.set(remembering(version, in: surfacedVersions()), forKey: surfacedKey)
	}

	private static func remember(_ version: String) {
		let updated = remembering(version, in: rememberedVersions())
		UserDefaults.standard.set(updated, forKey: notifiedKey)
	}

	// MARK: - Posting

	/// Announces the release unless the decision above says no. Safe to call after every check.
	@MainActor
	static func notifyIfNeeded(_ release: SelfUpdateRelease) async {
		let settings = await UNUserNotificationCenter.current().notificationSettings()
		let ignored = SelfUpdateManager.shared.ignoredVersions
		guard shouldNotify(
			version: release.version,
			isEnabled: isEnabled,
			authorization: settings.authorizationStatus,
			alreadyNotified: Set(rememberedVersions()),
			ignored: ignored,
			alreadySurfaced: Set(surfacedVersions()),
			isAppActive: UIApplication.shared.applicationState == .active
		) else { return }

		let content = UNMutableNotificationContent()
		content.title = String.localized("VexSign %@ is available", arguments: release.version)
		content.body = .localized("Open VexSign to review the release notes and install the update.")
		content.sound = .default
		content.threadIdentifier = threadIdentifier
		content.userInfo = ["version": release.version]
		content.interruptionLevel = .active

		// One identifier per version: a re-check replaces its own banner instead of stacking.
		let request = UNNotificationRequest(
			identifier: identifierPrefix + release.version,
			content: content,
			trigger: nil
		)

		do {
			try await UNUserNotificationCenter.current().add(request)
			remember(release.version)
			FileLogger.log("Notified about release \(release.version)", category: "update")
		} catch {
			// A failed delivery is not worth failing the check over; it is retried on the next one
			// because the version is only remembered after a successful add.
			FileLogger.log("Could not post release notification: \(error.localizedDescription)", category: "update")
		}
	}

	/// True when the tapped notification belongs to a release announcement.
	static func isReleaseNotification(_ identifier: String) -> Bool {
		identifier.hasPrefix(identifierPrefix)
	}

	/// A tap on the release banner opens the update sheet rather than leaving the user to find it.
	///
	/// The banner can outlive its release (the user updated elsewhere, or the version was ignored),
	/// and the sheet has nothing to show without a release — so re-check instead of presenting a
	/// blank sheet, and only present once something is actually available.
	@MainActor
	static func handleTap(identifier: String) {
		guard isReleaseNotification(identifier) else { return }
		let manager = SelfUpdateManager.shared
		if manager.available != nil {
			manager.presentUpdatePrompt = true
			return
		}
		Task {
			await manager.check()
			if manager.available != nil { manager.presentUpdatePrompt = true }
		}
	}
}
