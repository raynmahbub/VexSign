//
//  AutomationVisibility.swift
//  VexSign
//
//  One rule, asked from three places that are not the app's UI: the Web Manager
//  (HTTP), Shortcuts (App Intents) and anything else that reports or acts on the
//  library without a screen in front of the device owner.
//
//  The Hidden Apps Vault is opened with the owner's biometrics *inside* the app.
//  A Shortcut, a Home Screen tile or an HTTP client has no equivalent prompt, so
//  naming a vaulted app there would leak exactly what hiding it was for. The rule
//  lives here, with no UIKit, Vapor or storage dependency, so each surface can ask
//  it and the answer cannot drift between them.
//

import Foundation

enum AutomationVisibility {
	/// Whether a surface outside the UI may name, count, download or act on this app.
	///
	/// Rows without a UUID cannot be matched against the vault, so they stay visible:
	/// failing open here would hide unrelated apps from their owner. An empty UUID is
	/// treated the same way for the same reason.
	static func isVisible(uuid: String?, hiddenAppUUIDs: Set<String>) -> Bool {
		guard let uuid, !uuid.isEmpty else { return true }
		return !hiddenAppUUIDs.contains(uuid)
	}
}
