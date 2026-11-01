//
//  AccessibilityIdentifiers.swift
//  VexSign
//
//  Stable identifiers for the signing and install flows.
//
//  A UI test cannot match on localised text: the app asks for 2,400+ strings and any of them can
//  be reworded. Matching on an identifier from here keeps a test stable while the copy moves, and
//  keeps the accessibility tree readable in Xcode's debugger.
//
//  An identifier is a contract — renaming one breaks whatever drives it — so they live in a single
//  file, share a prefix, and are covered by a test that keeps them unique.
//

import Foundation

enum AX {
	/// Every identifier starts with this, so a stale one is obvious in a UI-test log.
	static let prefix = "vexsign"

	/// The signing sheet: start, stop, and what it shows while it runs.
	enum Signing {
		static let start = "vexsign.signing.start"
		static let stop = "vexsign.signing.stop"
		static let progress = "vexsign.signing.progress"
		static let console = "vexsign.signing.console"
	}

	/// The queue that installs a signed bundle.
	enum Install {
		static let start = "vexsign.install.start"
		static let progress = "vexsign.install.progress"
	}

	/// What a library row says about one app.
	enum Library {
		static let installedBadge = "vexsign.library.installed"
		static let updateBadge = "vexsign.library.update"
		static let lockBadge = "vexsign.library.locked"
	}

	/// Every identifier, for the test that keeps them unique and prefixed.
	static var all: [String] {
		[
			Signing.start, Signing.stop, Signing.progress, Signing.console,
			Install.start, Install.progress,
			Library.installedBadge, Library.updateBadge, Library.lockBadge
		]
	}
}
