//
//  VexSignIntents+Actions.swift
//  VexSign
//
//  The parameterised half of the Shortcuts surface: everything in
//  VexSignIntents.swift takes no arguments, these take an app, a repository or a
//  destination. Same rule as the rest of the file — each intent is one call into
//  a manager that already exists, so nothing here re-implements signing,
//  downloading or refresh logic.
//

import Foundation
import AppIntents
import SwiftUI
import NimbleExtensions

// MARK: - Sign an app

@available(iOS 17.0, *)
struct SignAppIntent: AppIntent {
	static var title: LocalizedStringResource = "Sign App"
	static var description = IntentDescription("Signs a library app with your saved options and default certificate.")

	@Parameter(title: "App", requestValueDialog: "Which app should VexSign sign?")
	var app: VexSignAppEntity

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		guard let target = VexSignAppQuery.app(for: app.uuid) else {
			return .result(dialog: IntentDialog(stringLiteral: .localized("That app is no longer in your library.")))
		}

		guard AutoSignIdentityPolicy.decide(
			identity: SigningModeManager.shared.identityChoice
		) == .allow else {
			TabSelectionObserver.shared.requestProvisioningReview(for: target)
			return .result(dialog: IntentDialog(stringLiteral: .localized("Apple Account identity selected. Opening the attended provisioning review in VexSign; no stored certificate was substituted.")))
		}

		switch await AutoSignManager.shared.sign(target) {
		case .success(let signed):
			return .result(dialog: IntentDialog(stringLiteral: String.localized(
				"Signed %@.",
				arguments: signed.name ?? target.name ?? .localized("app")
			)))
		case .failure(let error):
			return .result(dialog: IntentDialog(stringLiteral: String.localized(
				"Could not sign %@: %@",
				arguments: target.name ?? .localized("app"), error.localizedDescription
			)))
		}
	}
}

/// An explicit foreground reinstall request, not Apple account/profile renewal.
@available(iOS 17.0, *)
struct RepeatInstallIntent: AppIntent {
	static var title: LocalizedStringResource = "Re-sign and Queue Install"
	static var description = IntentDescription("Re-signs a signed library copy using its saved certificate and opens the install queue. Does not extend the profile expiry.")
	static var openAppWhenRun = true

	@Parameter(title: "App", requestValueDialog: "Which signed app should VexSign reinstall?")
	var app: VexSignAppEntity

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		guard let target = VexSignAppQuery.app(for: app.uuid) else {
			return .result(dialog: IntentDialog(stringLiteral: .localized("That app is no longer in your library.")))
		}
		if AppLockManager.shared.isAppLocked(app.uuid), !AppLockManager.shared.isSessionUnlocked(app.uuid) {
			return .result(dialog: IntentDialog(stringLiteral: .localized("Unlock this library app in VexSign first.")))
		}
		guard AutoSignIdentityPolicy.decide(
			identity: SigningModeManager.shared.identityChoice
		) == .allow else {
			TabSelectionObserver.shared.requestProvisioningReview(for: target)
			return .result(dialog: IntentDialog(stringLiteral: .localized("Apple Account identity selected. Opening the attended provisioning review in VexSign; no stored certificate was substituted.")))
		}
		_ = try await AutoSignManager.shared.sign(target, repeatInstall: true).get()
		return .result(dialog: IntentDialog(stringLiteral: .localized("Re-signed and queued for installation. Check the install result in VexSign.")))
	}
}

/// Home Screen shortcuts may open a recovery record, never perform its actions.
@available(iOS 17.0, *)
struct OpenFixtureSlotIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Fixture Slot Manager"
    static var description = IntentDescription("Opens manual recovery for a signed marker fixture. Nothing is installed or removed.")
    static var openAppWhenRun = true

    @Parameter(title: "Saved fixture backup") var app: FixtureBackupEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !AppLockManager.shared.isLocked else {
            return .result(dialog: IntentDialog(stringLiteral: .localized("Unlock VexSign before opening a backup.")))
        }
        guard let entry = try FixtureSlotStorage.load(app.id)?.recoveryEntry else {
            return .result(dialog: IntentDialog(stringLiteral: .localized("This fixture backup is missing or has no saved lock identity. Open fixture recovery in Settings.")))
        }
        guard AppLockManager.shared.canOpenFixtureBackup(entry) else {
            return .result(dialog: IntentDialog(stringLiteral: .localized("Reveal or unlock the protected backup in VexSign first.")))
        }
        TabSelectionObserver.shared.selectedTab = .settings
        TabSelectionObserver.shared.fixtureSlotRequest = FixtureSlotRoute(copyID: entry.id, uuid: entry.uuid)
        return .result(dialog: IntentDialog(stringLiteral: .localized("Opening fixture recovery review.")))
    }
}

/// Navigation only. A Shortcut is not consent to modify the Apple account.
@available(iOS 17.0, *)
struct CellularRenewalReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Review Renewal over Cellular"
    static var description = IntentDescription("Opens the foreground profile renewal review. Requires mobile data and your confirmation in VexSign.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        TabSelectionObserver.shared.selectedTab = .settings
        TabSelectionObserver.shared.cellularRenewalRequested = true
        return .result()
    }
}

/// Navigation only: a Shortcut opens the manual account review, where provisioning,
/// key export, signing and installation are each approved separately.
@available(iOS 17.0, *)
struct ReviewAccountRefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Review Account Refresh"
    static var description = IntentDescription("Opens the manual Apple Account refresh review. Nothing is renewed by the Shortcut itself.")
    static var openAppWhenRun = true

    @Parameter(title: "Only when a refresh is due", default: true)
    var onlyWhenDue: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let hasDueRefresh = RenewalScheduleCoordinator.shared.plans.contains {
            $0.isAppleAccountCredential && $0.status.isActionable
        }
        if onlyWhenDue && !hasDueRefresh {
            return .result(dialog: IntentDialog(stringLiteral: .localized("No Apple Account refresh is due. Open VexSign to review provisioning at any time.")))
        }
        // An explicit Shortcut is a foreground decision, not a background grant.
        let decision = AccountRefreshAutomationPolicy.decide(
            isEnabled: true,
            hasDueRefresh: true,
            sessionReady: RenewalRenewabilityState.shared.isAccountSessionReady,
            fromBackground: false
        )
        guard decision == .openReview else {
            return .result(dialog: IntentDialog(stringLiteral: .localized("This Shortcut cannot start an account refresh. Open VexSign to review it.")))
        }
        TabSelectionObserver.shared.selectedTab = .settings
        TabSelectionObserver.shared.accountRefreshRequested = true
        return .result(dialog: IntentDialog(stringLiteral: .localized("Opening account refresh review. Approve each step in VexSign.")))
    }
}

// MARK: - Install an app

@available(iOS 17.0, *)
struct InstallAppIntent: AppIntent {
	static var title: LocalizedStringResource = "Install App"
	static var description = IntentDescription("Queues a signed library app for installation on this device.")

	@Parameter(title: "App", requestValueDialog: "Which app should VexSign install?")
	var app: VexSignAppEntity

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		guard let target = VexSignAppQuery.app(for: app.uuid) else {
			return .result(dialog: IntentDialog(stringLiteral: .localized("That app is no longer in your library.")))
		}

		guard target.isSigned else {
			return .result(dialog: IntentDialog(stringLiteral: String.localized(
				"%@ is not signed yet. Run “Sign App” first.",
				arguments: target.name ?? .localized("That app")
			)))
		}

		InstallQueue.shared.enqueue(target)
		InstallQueue.shared.activate()

		return .result(dialog: IntentDialog(stringLiteral: String.localized(
			"Queued %@ for install.",
			arguments: target.name ?? .localized("the app")
		)))
	}
}

// MARK: - Refresh repositories

@available(iOS 17.0, *)
struct RefreshSourcesIntent: AppIntent {
	static var title: LocalizedStringResource = "Refresh Repositories"
	static var description = IntentDescription("Re-fetches every repository, or just the one you pick.")

	@Parameter(title: "Repository", requestValueDialog: "Which repository should VexSign refresh?")
	var source: VexSignSourceEntity?

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		let all = VexSignSourceQuery.sources()
		let targets: [AltSource]
		if let source, let match = VexSignSourceQuery.source(for: source.url) {
			targets = [match]
		} else if source != nil {
			return .result(dialog: IntentDialog(stringLiteral: .localized("That repository was removed.")))
		} else {
			targets = all
		}

		guard !targets.isEmpty else {
			return .result(dialog: IntentDialog(stringLiteral: .localized("You have not added any repositories yet.")))
		}

		await SourceCatalogStore.shared.fetchSources(targets, refresh: true, configuredSources: all)

		return .result(dialog: IntentDialog(stringLiteral: String.localized(
			"Requested refresh for %lld repositories. Check repository health for results.",
			arguments: targets.count
		)))
	}
}

// MARK: - Certificate check

@available(iOS 17.0, *)
struct CheckCertificatesIntent: AppIntent {
	static var title: LocalizedStringResource = "Check Certificates"
	static var description = IntentDescription("Validates every certificate in the library locally: expiry, revocation flags and PPQ.")

	/// Off by default: turning it on sends certificate identifiers to the
	/// configured responder, which is exactly what the in-app switch says.
	@Parameter(title: "Ask the responder too (sends certificate identifiers off-device)", default: false)
	var online: Bool

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		let checker = BatchCertChecker.shared
		await checker.checkAll(online: online)

		let summary = checker.summary
		let total = checker.results.count

		guard total > 0 else {
			return .result(dialog: IntentDialog(stringLiteral: .localized("There are no certificates to check.")))
		}

		var message = String.localized(
			"%lld certificates: %lld valid, %lld expiring soon, %lld expired, %lld revoked.",
			arguments: total, summary.valid, summary.expiring, summary.expired, summary.revoked
		)
		// In date but never checked for revocation is not "valid"; say so instead of dropping it.
		if checker.notCheckedCount > 0 {
			message += " " + String.localized("%lld in date, not checked for revocation.", arguments: checker.notCheckedCount)
		}
		return .result(dialog: IntentDialog(stringLiteral: message))
	}
}

// MARK: - Open a section

@available(iOS 17.0, *)
struct OpenVexSignIntent: AppIntent {
	static var title: LocalizedStringResource = "Open VexSign"
	static var description = IntentDescription("Opens VexSign at a specific place.")

	static var openAppWhenRun: Bool = true

	@Parameter(title: "Section", default: .home, requestValueDialog: "Where should VexSign open?")
	var section: VexSignSection

	@MainActor
	func perform() async throws -> some IntentResult {
		if section == .ipaExplorer {
			AppNavigationManager.shared.openIPAExplorer()
		} else if let tab = section.tab {
			TabSelectionObserver.shared.selectedTab = tab
		}
		return .result()
	}
}

// MARK: - Download from a URL

@available(iOS 17.0, *)
struct DownloadFromURLIntent: AppIntent {
	static var title: LocalizedStringResource = "Download File"
	static var description = IntentDescription("Starts a VexSign download from a URL. Game Mode still refuses it.")

	@Parameter(title: "URL", requestValueDialog: "What should VexSign download?")
	var url: URL

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		guard url.scheme == "http" || url.scheme == "https" else {
			return .result(dialog: IntentDialog(stringLiteral: .localized("That is not an http(s) URL.")))
		}

		if GameMode.isEnabled {
			return .result(dialog: IntentDialog(stringLiteral: .localized(
				"Game Mode is on, so downloads are paused. Turn it off to download this."
			)))
		}

		let download = DownloadManager.shared.startDownload(from: url)
		return .result(dialog: IntentDialog(stringLiteral: String.localized(
			"Downloading %@.",
			arguments: download.fileName
		)))
	}
}

// MARK: - Game Mode

@available(iOS 17.0, *)
struct SetGameModeIntent: AppIntent {
	static var title: LocalizedStringResource = "Set Game Mode"
	static var description = IntentDescription("Turns Game Mode on or off. It pauses downloads and background work only.")

	@Parameter(title: "Enabled", default: true)
	var enabled: Bool

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		GameMode.setEnabled(enabled)
		return .result(dialog: IntentDialog(stringLiteral: enabled
			? .localized("Game Mode is on. Downloads and background work are paused.")
			: .localized("Game Mode is off.")))
	}
}

// MARK: - Library summary

/// Returns a number so automations can branch on it ("if updates > 0 …").
@available(iOS 17.0, *)
struct LibrarySummaryIntent: AppIntent {
	static var title: LocalizedStringResource = "Get Pending Update Count"
	static var description = IntentDescription("Returns how many library apps have an update available.")

	@MainActor
	func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
		let count = AppUpdateChecker.shared.updateCount
		return .result(
			value: count,
			dialog: IntentDialog(stringLiteral: count == 0
				? .localized("Everything is up to date.")
				: String.localized("%lld updates available.", arguments: count))
		)
	}
}
