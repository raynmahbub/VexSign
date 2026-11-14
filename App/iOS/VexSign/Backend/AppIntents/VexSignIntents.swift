//
//  VexSignIntents.swift
//  VexSign
//
//  Shortcuts / Home Screen quick actions over the existing managers. Each intent is one
//  call into a manager that already exists, so they are thin by design.
//

import Foundation
import AppIntents
import SwiftUI
import NimbleExtensions

// MARK: - Update All

@available(iOS 17.0, *)
struct UpdateAllIntent: AppIntent {
	static var title: LocalizedStringResource = "Update All Apps"
	static var description = IntentDescription("Checks every source and signs + queues every app with an available update.")

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		// `run` returns nil for a pass that never started (off, busy, Game Mode) and for one
		// that was cancelled. Both used to read as "Everything is up to date", which was true
		// of neither: nothing had been compared. Ask first, then report what happened.
		if let blocker = AutomationAvailability.blocker(
			enabled: BackgroundAutomationPreferences.isEnabled,
			running: BackgroundAutomation.isRunning,
			gameMode: GameMode.isEnabled,
			updateAllRunning: UpdateAllManager.shared.isRunning
		) {
			return .result(dialog: IntentDialog(stringLiteral: AutomationAvailability.message(for: blocker)))
		}

		let result: AutomationRunResult? = await BackgroundAutomation.run(fromBackground: true)
		guard let result else {
			return .result(dialog: IntentDialog(stringLiteral: AutomationDialogue.unfinished))
		}

		return .result(dialog: IntentDialog(stringLiteral: AutomationDialogue.message(
			found: result.foundUpdates,
			signed: result.signed,
			failed: result.failed
		)))
	}
}

// MARK: - Clean Now

@available(iOS 17.0, *)
struct CleanNowIntent: AppIntent {
	static var title: LocalizedStringResource = "Clean Now"
	static var description = IntentDescription("Runs the automatic cleanup sweep immediately.")

	func perform() async throws -> some IntentResult & ProvidesDialog {
		let summary: CleanupSummary = await MainActor.run {
			CleanupManager.shared.cleanNow()
		}

		var parts: [String] = []
		if !summary.isIdle {
			parts.append(String.localized("Freed %@.", arguments: summary.freedBytes.formattedFileSize))
		}
		// Temporary files and leftovers wait while something is signing or installing. Say so,
		// instead of "Nothing to clean up." for a run that left them on purpose.
		if let notice = summary.deferralNotice {
			parts.append(notice)
		}
		if parts.isEmpty {
			parts.append(.localized("Nothing to clean up."))
		}
		return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: " ")))
	}
}

// MARK: - Sign Latest Download

@available(iOS 17.0, *)
struct SignLatestDownloadIntent: AppIntent {
	static var title: LocalizedStringResource = "Sign Latest Download"
	static var description = IntentDescription("Signs the most recently added unsigned app with your saved options.")

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		let unsigned = Storage.shared.getAllApps().filter { !$0.isSigned }
		// Most recent first.
		let latest = unsigned.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.first

		guard let app = latest else {
			return .result(dialog: IntentDialog(stringLiteral: .localized("There is nothing to sign.")))
		}

		let result = await AutoSignManager.shared.sign(app)
		switch result {
		case .success:
			return .result(dialog: IntentDialog(stringLiteral: String.localized("Signed %@.", arguments: app.name ?? .localized("the app"))))
		case .failure(let error):
			throw error
		}
	}
}

// MARK: - Open IPA Explorer

@available(iOS 17.0, *)
struct OpenIPAExplorerIntent: AppIntent {
	static var title: LocalizedStringResource = "Open IPA Explorer"
	static var description = IntentDescription("Opens the IPA Explorer to browse and edit an app bundle.")

	static var openAppWhenRun: Bool = true

	@MainActor
	func perform() async throws -> some IntentResult {
		// Navigate the UI to the explorer.
		AppNavigationManager.shared.openIPAExplorer()
		return .result()
	}
}

// MARK: - Shortcuts provider

/// Binds the intents into the Shortcuts gallery.
///
/// Apple caps an app at ten `AppShortcut` phrases; the two that are missing here
/// (`SetGameModeIntent`, `LibrarySummaryIntent`) are still fully usable from the
/// Shortcuts app and from automations — they just do not get a Siri phrase of
/// their own. `ShortcutsSettingsView` lists all of them.
@available(iOS 17.0, *)
struct VexSignShortcutsProvider: AppShortcutsProvider {
	@AppShortcutsBuilder
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: UpdateAllIntent(),
			phrases: ["Update all apps in \(.applicationName)"],
			shortTitle: "Update All",
			systemImageName: "arrow.triangle.2.circlepath"
		)
		AppShortcut(
			intent: CleanNowIntent(),
			phrases: ["Clean \(.applicationName) storage now"],
			shortTitle: "Clean Now",
			systemImageName: "sparkles"
		)
		AppShortcut(
			intent: SignLatestDownloadIntent(),
			phrases: ["Sign my latest download in \(.applicationName)"],
			shortTitle: "Sign Latest Download",
			systemImageName: "signature"
		)
		AppShortcut(
			intent: SignAppIntent(),
			phrases: ["Sign an app with \(.applicationName)"],
			shortTitle: "Sign App",
			systemImageName: "signature"
		)
		AppShortcut(
			intent: InstallAppIntent(),
			phrases: ["Install an app with \(.applicationName)"],
			shortTitle: "Install App",
			systemImageName: "square.and.arrow.down"
		)
		AppShortcut(
			intent: RefreshSourcesIntent(),
			phrases: ["Refresh my repositories in \(.applicationName)"],
			shortTitle: "Refresh Repositories",
			systemImageName: "arrow.clockwise"
		)
		AppShortcut(
			intent: CheckCertificatesIntent(),
			phrases: ["Check my certificates in \(.applicationName)"],
			shortTitle: "Check Certificates",
			systemImageName: "checkmark.shield"
		)
		AppShortcut(
			intent: OpenVexSignIntent(),
			phrases: ["Open \(.applicationName)"],
			shortTitle: "Open VexSign",
			systemImageName: "square.grid.2x2"
		)
		AppShortcut(
			intent: DownloadFromURLIntent(),
			phrases: ["Download a file with \(.applicationName)"],
			shortTitle: "Download File",
			systemImageName: "arrow.down.circle"
		)
		AppShortcut(
			intent: OpenIPAExplorerIntent(),
			phrases: ["Open the IPA Explorer in \(.applicationName)"],
			shortTitle: "Open IPA Explorer",
			systemImageName: "doc.text.magnifyingglass"
		)
	}
}

// MARK: - Catalogue for the settings UI

/// One row per intent, so Settings can show what exists without hard-coding a
/// second list that drifts away from the provider above.
@available(iOS 17.0, *)
enum VexSignShortcutCatalogue {
	struct Entry: Identifiable {
		let id: String
		let title: String
		let detail: String
		let systemImage: String
		/// Siri phrase, when the intent is in `VexSignShortcutsProvider`.
		let phrase: String?
	}

	static let entries: [Entry] = [
		Entry(
			id: "updateAll",
			title: .localized("Update All"),
			detail: .localized("Checks every repository and signs + queues everything with an update."),
			systemImage: "arrow.triangle.2.circlepath",
			phrase: "Update all apps in VexSign"
		),
		Entry(
			id: "signApp",
			title: .localized("Sign App"),
			detail: .localized("Signs one library app you pick with your saved options."),
			systemImage: "signature",
			phrase: "Sign an app with VexSign"
		),
		Entry(
			id: "signLatest",
			title: .localized("Sign Latest Download"),
			detail: .localized("Signs the most recently added unsigned app."),
			systemImage: "square.and.arrow.down.on.square",
			phrase: "Sign my latest download in VexSign"
		),
		Entry(
			id: "installApp",
			title: .localized("Install App"),
			detail: .localized("Queues a signed app for installation."),
			systemImage: "square.and.arrow.down",
			phrase: "Install an app with VexSign"
		),
		Entry(
			id: "refreshSources",
			title: .localized("Refresh Repositories"),
			detail: .localized("Re-fetches every repository, or just one."),
			systemImage: "arrow.clockwise",
			phrase: "Refresh my repositories in VexSign"
		),
		Entry(
			id: "checkCertificates",
			title: .localized("Check Certificates"),
			detail: .localized("Local expiry and revocation pass over every certificate."),
			systemImage: "checkmark.shield",
			phrase: "Check my certificates in VexSign"
		),
		Entry(
			id: "cleanNow",
			title: .localized("Clean Now"),
			detail: .localized("Runs the cleanup sweep immediately."),
			systemImage: "sparkles",
			phrase: "Clean VexSign storage now"
		),
		Entry(
			id: "download",
			title: .localized("Download File"),
			detail: .localized("Starts a download from a URL. Game Mode still refuses it."),
			systemImage: "arrow.down.circle",
			phrase: "Download a file with VexSign"
		),
		Entry(
			id: "openSection",
			title: .localized("Open VexSign"),
			detail: .localized("Opens the app at a chosen place, including the IPA Explorer."),
			systemImage: "square.grid.2x2",
			phrase: "Open VexSign"
		),
		Entry(
			id: "gameMode",
			title: .localized("Set Game Mode"),
			detail: .localized("Pauses downloads and background work. No Siri phrase — use it in an automation."),
			systemImage: "gamecontroller",
			phrase: nil
		),
		Entry(
			id: "updateCount",
			title: .localized("Get Pending Update Count"),
			detail: .localized("Returns a number, so a shortcut can branch on it."),
			systemImage: "number",
			phrase: nil
		)
	]
}
