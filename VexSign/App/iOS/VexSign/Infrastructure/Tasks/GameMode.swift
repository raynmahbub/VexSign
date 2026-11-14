//
//  GameMode.swift
//  VexSign
//
//  Game Mode keeps VexSign off the network while you are playing: downloads are refused
//  (new ones and paused ones), the scheduled automation pass is skipped, and whatever is
//  already in the Library is left alone. It is deliberately a *pause*, not a queue — nothing
//  is fetched in the background "because Game Mode was on", which is the whole point.
//
//  This is the app-side half of the feature. The other half is `Options.gameMode` on the
//  signing screen, which stamps `GCSupportsGameMode` into a *signed* app's Info.plist.
//

import Foundation
import UIKit
import NimbleExtensions

// MARK: - Preferences
/// Deliberately not actor isolated: the guards live inside network entry points, some of which
/// (background-task handlers, URLSession delegate callbacks) are not on the main actor.
enum GameMode {
	static let enabledKey = "VexSign.gameMode"

	static var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: enabledKey)
	}

	/// One line of the "what this turns off" list in Settings.
	struct Effect: Identifiable {
		let systemImage: String
		let title: String
		let detail: String

		var id: String { title }
	}

	/// What the toggle turns off, shown in Settings so the switch is honest about its reach.
	static let effects: [Effect] = [
		Effect(
			systemImage: "arrow.down.circle",
			title: .localized("Downloads are paused"),
			detail: .localized("Nothing new is fetched, and paused downloads stay paused until the mode is off.")
		),
		Effect(
			systemImage: "bolt.badge.clock",
			title: .localized("Automatic updates are skipped"),
			detail: .localized("The scheduled check-and-sign pass does not run, so no data is spent in the background.")
		),
		Effect(
			systemImage: "checkmark.seal",
			title: .localized("Signing and installing keep working"),
			detail: .localized("Anything already on disk can still be signed, tweaked and installed. This mode only stops the network.")
		)
	]

	// MARK: Lifecycle

	/// Single place the switch flips, so Settings and the "turn it off" alert behave the same.
	@MainActor
	static func setEnabled(_ enabled: Bool) {
		guard enabled != isEnabled else { return }
		UserDefaults.standard.set(enabled, forKey: enabledKey)
		enabled ? enable() : disable()
	}

	/// Applied when the switch flips on: an in-flight download would otherwise keep pulling data
	/// for as long as the user is playing.
	@MainActor
	static func enable() {
		let manager = DownloadManager.shared
		let running = manager.downloads.filter { ($0.isActive || $0.progress > 0) && $0.progress < 1.0 && !$0.isPaused }

		manager.pauseAllDownloads()
		FileLogger.log("Game Mode on — paused \(running.count) download(s)", category: "download")
		SigningLog.shared.info(.localized("Game Mode on — downloads paused"), category: "download")

		Toast.info(
			running.isEmpty
				? .localized("Game Mode is on")
				: .localized("Game Mode is on — %lld download(s) paused", arguments: running.count),
			systemImage: "gamecontroller"
		)
	}

	@MainActor
	static func disable() {
		FileLogger.log("Game Mode off", category: "download")
		SigningLog.shared.info(.localized("Game Mode off"), category: "download")
		Toast.info(.localized("Game Mode is off"), systemImage: "gamecontroller")
		if DownloadPreferences.resumeAfterGameMode {
			DownloadManager.shared.resumeAllDownloads()
		}
	}

	// MARK: Reporting

	/// Every blocked entry point explains itself the same way, so the user never has to guess
	/// why a button did nothing.
	@MainActor
	static func reportBlocked(_ action: String) {
		UINotificationFeedbackGenerator().notificationOccurred(.warning)
		UIAlertController.showAlertWithOptions(
			title: .localized("Game Mode is On"),
			message: .localized("%@ is paused while Game Mode is on. Turn it off in Settings to continue.", arguments: action),
			actions: [
				(.localized("Turn Off Game Mode"), .default, {
					// The handler is a plain closure, so hop rather than assume main.
					Task { @MainActor in GameMode.setEnabled(false) }
				}),
				(.localized("Keep It On"), .cancel, nil)
			]
		)
	}

	/// Lightweight variant for flows that must not be interrupted by an alert (batch runners).
	static func reportBlockedInline(_ action: String) {
		Toast.error(
			.localized("%@ is paused while Game Mode is on.", arguments: action),
			duration: .long
		)
	}
}
