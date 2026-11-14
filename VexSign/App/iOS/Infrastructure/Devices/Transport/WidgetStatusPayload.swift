//
//  WidgetStatusPayload.swift
//  VexSign
//
//  The snapshot the Home Screen status widget renders. It lives in the app group
//  both targets already share (`group.com.vexsign.app`), so the extension never
//  touches CoreData or the Keychain — the app writes, the widget reads.
//
//  Compiled into BOTH targets (see the widget target's membership exceptions in
//  project.pbxproj), so it stays iOS 16-safe and dependency-free.
//

import Foundation
import SwiftUI

struct WidgetStatusPayload: Codable, Equatable {
	/// Days until the active certificate expires; nil when no certificate exists.
	var certDaysRemaining: Int?
	/// Display name of the certificate the countdown belongs to.
	var certName: String?
	/// True when the active certificate was reported revoked.
	var certRevoked: Bool
	/// Apps a source has a newer version of.
	var pendingUpdates: Int
	/// Everything in the library.
	var installedCount: Int
	/// Signed subset of the library.
	var signedCount: Int
	/// Free space left for VexSign, in bytes.
	var availableBytes: Int64?
	var lastUpdated: Date

	// MARK: Sharing

	static let appGroupIdentifier = "group.com.vexsign.app"
	static let defaultsKey = "VexSign.widgetStatusPayload"
	static let downloadControlKey = "VexSign.downloadControlCommand"

	static var sharedDefaults: UserDefaults? {
		UserDefaults(suiteName: appGroupIdentifier)
	}

	/// Writes the payload into the app group. Returns false when the group is
	/// unavailable (e.g. a build without the entitlement), so callers can log it.
	@discardableResult
	func store() -> Bool {
		guard let defaults = Self.sharedDefaults else { return false }
		guard let data = try? JSONEncoder().encode(self) else { return false }
		defaults.set(data, forKey: Self.defaultsKey)
		return true
	}

	static func load() -> WidgetStatusPayload? {
		guard
			let defaults = sharedDefaults,
			let data = defaults.data(forKey: defaultsKey)
		else { return nil }
		return try? JSONDecoder().decode(WidgetStatusPayload.self, from: data)
	}

	static func clear() {
		sharedDefaults?.removeObject(forKey: defaultsKey)
	}

	/// Live Activity intents execute in the widget extension process. A Darwin
	/// notification cannot safely carry the command back into the app, so the
	/// shared app group is used as a tiny one-shot command mailbox.
	static func requestDownloadControl(_ command: String) {
		sharedDefaults?.set(command, forKey: downloadControlKey)
		sharedDefaults?.synchronize()
	}

	static func consumeDownloadControl() -> String? {
		guard let defaults = sharedDefaults,
		      let command = defaults.string(forKey: downloadControlKey)
		else { return nil }
		defaults.removeObject(forKey: downloadControlKey)
		return command
	}

	/// Shown in the gallery and in previews before the app has written anything.
	static var placeholder: WidgetStatusPayload {
		WidgetStatusPayload(
			certDaysRemaining: 30,
			certName: "Certificate",
			certRevoked: false,
			pendingUpdates: 3,
			installedCount: 12,
			signedCount: 8,
			availableBytes: 4_300_000_000,
			lastUpdated: Date()
		)
	}

	// MARK: Presentation

	/// Red inside a week, orange inside a month, green otherwise.
	var certTint: Color {
		if certRevoked { return .red }
		guard let days = certDaysRemaining else { return .secondary }
		if days < 7 { return .red }
		if days < 30 { return .orange }
		return .green
	}

	var updatesTint: Color {
		pendingUpdates > 0 ? .orange : .secondary
	}

	var certLabel: String {
		guard let days = certDaysRemaining else { return "—" }
		return days <= 0 ? "0d" : "\(days)d"
	}

	var isStale: Bool {
		Date().timeIntervalSince(lastUpdated) > 60 * 60 * 24
	}
}
