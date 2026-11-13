//
//  BackgroundAutomation.swift
//  VexSign
//
//  The scheduled "Do-Not-Disturb of signing": one opt-in pass that refreshes sources,
//  recomputes updates, and either just notifies (notify-only) or signs + queues flagged
//  apps before running the Auto Cleanup sweep — then posts a single summary notification.
//  Installing still needs the user in the loop, which is the honest ceiling iOS gives us.
//

import Foundation
import SwiftUI
import CoreData
import UserNotifications
import AltSourceKit
import NimbleExtensions

enum BackgroundAutomationPolicy: String, CaseIterable {
	case notifyOnly
	case signAndQueue

	var localizedDescription: String {
		switch self {
		case .notifyOnly: .localized("Notify only")
		case .signAndQueue: .localized("Sign & queue")
		}
	}

	var localizedDetail: String {
		switch self {
		case .notifyOnly:
			.localized("Checks for updates and tells you what is new. Nothing is signed or downloaded.")
		case .signAndQueue:
			.localized("Checks for updates, then signs apps allowed by your auto-update settings. If automatic install queueing is enabled, it adds them to the install queue. iOS decides when the background task runs and may require installation confirmation.")
		}
	}
}

// MARK: - Schedule interval
enum BackgroundAutomationInterval: Int, CaseIterable, Identifiable {
	case hourly = 3_600
	case everyThreeHours = 10_800
	case everySixHours = 21_600
	case everyTwelveHours = 43_200
	case daily = 86_400

	var id: Int { rawValue }

	var title: String {
		switch self {
		case .hourly: .localized("Hourly")
		case .everyThreeHours: .localized("Every 3 Hours")
		case .everySixHours: .localized("Every 6 Hours")
		case .everyTwelveHours: .localized("Every 12 Hours")
		case .daily: .localized("Daily")
		}
	}
}

// MARK: - Preferences
struct BackgroundAutomationPreferences {
	static let enabledKey = "VexSign.automation.enabled"
	static let policyKey = "VexSign.automation.policy"
	static let intervalKey = "VexSign.automation.interval"

	static var isEnabled: Bool {
		get { UserDefaults.standard.bool(forKey: enabledKey) }
		set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
	}

	static var policy: BackgroundAutomationPolicy {
		get { BackgroundAutomationPolicy(rawValue: UserDefaults.standard.string(forKey: policyKey) ?? "") ?? .notifyOnly }
		set { UserDefaults.standard.set(newValue.rawValue, forKey: policyKey) }
	}

	static var interval: BackgroundAutomationInterval {
		get {
			let rawValue = UserDefaults.standard.object(forKey: intervalKey) as? Int ?? BackgroundAutomationInterval.everySixHours.rawValue
			return BackgroundAutomationInterval(rawValue: rawValue) ?? .everySixHours
		}
		set { UserDefaults.standard.set(newValue.rawValue, forKey: intervalKey) }
	}
}

// MARK: - Result
struct AutomationRunResult {
	let refreshedSources: Int
	let foundUpdates: Int
	var signed: Int
	var queueAdded: Int
	var skipped: Int
	var cleanup: CleanupSummary?
    var failed: Int = 0
    var githubReleaseReviews: Int = 0
}

// Stores counts and outcomes only; no app names, credentials or source URLs.
struct AutomationHistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let fromBackground: Bool
    let outcome: String
    let updates: Int
    let signed: Int
    let queued: Int
    let skipped: Int
    // Optional fields keep histories written by earlier builds decodable.
    let failed: Int?
    let duration: TimeInterval?
}

@MainActor
final class AutomationHistoryStore: ObservableObject {
    static let shared = AutomationHistoryStore()
    private static let key = "VexSign.automation.history"
    @Published private(set) var entries: [AutomationHistoryEntry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            do {
                entries = Array(try JSONDecoder().decode([AutomationHistoryEntry].self, from: data).prefix(50))
            } catch {
                FileLogger.log("Could not decode automation history: \(error)", category: "update")
            }
        }
    }

    func record(_ outcome: String, fromBackground: Bool, result: AutomationRunResult? = nil, duration: TimeInterval? = nil) {
        entries.insert(AutomationHistoryEntry(
            id: UUID(), date: Date(), fromBackground: fromBackground, outcome: outcome,
            updates: result?.foundUpdates ?? 0, signed: result?.signed ?? 0,
            queued: result?.queueAdded ?? 0, skipped: result?.skipped ?? 0,
            failed: result?.failed, duration: duration
        ), at: 0)
        entries = Array(entries.prefix(50))
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(entries), forKey: Self.key)
        } catch {
            FileLogger.log("Could not save automation history: \(error)", category: "update")
        }
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

// MARK: - Runner
@MainActor
enum BackgroundAutomation {
    /// Read by `UpdateAllIntent` so a Shortcut can say why a pass did not start instead of
    /// reporting "Everything is up to date" for a run that never happened.
    static private(set) var isRunning = false
	/// One full maintenance pass. `fromBackground` keeps it quiet (no toasts).
	static func run(fromBackground: Bool = false) async -> AutomationRunResult? {
		guard BackgroundAutomationPreferences.isEnabled else {
            AutomationHistoryStore.shared.record("disabled", fromBackground: fromBackground)
            return nil
        }
        guard !isRunning else {
            AutomationHistoryStore.shared.record("busy", fromBackground: fromBackground)
            return nil
        }

		// Game Mode: the pass refreshes every source and downloads updates, which is exactly
		// the background traffic the mode exists to stop.
		guard !GameMode.isEnabled else {
			AutomationHistoryStore.shared.record("gameMode", fromBackground: fromBackground)
			FileLogger.log("Automation skipped — Game Mode is on", category: "update")
			if !fromBackground {
				GameMode.reportBlockedInline(.localized("Automatic update checks"))
			}
			return nil
		}

        // Avoid reading another queue's counters as this run's result.
        guard !UpdateAllManager.shared.isRunning else {
            AutomationHistoryStore.shared.record("busy", fromBackground: fromBackground)
            return nil
        }

        let startedAt = Date()
        isRunning = true
        defer { isRunning = false }

		// The only chance a scheduled pass has to notice a new VexSign release. Checked before the
		// source guard: self-updates do not depend on any repository being configured.
		await SelfUpdateManager.shared.check()
		guard !Task.isCancelled else {
			AutomationHistoryStore.shared.record("cancelled", fromBackground: fromBackground)
			return nil
		}
        let trackedReleases = await GitHubSubscriptionStore.shared.checkDueSubscriptions()
        guard !Task.isCancelled else {
            AutomationHistoryStore.shared.record("cancelled", fromBackground: fromBackground)
            return nil
        }

		let storage = Storage.shared
		var policy = BackgroundAutomationPreferences.policy
		// A scheduled pass signs only under an active grant for the selected certificate. A
		// pass the user started is attended, so the preference alone decides it. Without a
		// grant the pass still refreshes, matches and notifies; it does not sign.
		if fromBackground, policy == .signAndQueue {
			let certificateUUID = storage.getCertificate(
				for: UserDefaults.standard.integer(forKey: "vexsign.selectedCert")
			)?.uuid
			let decision = UnattendedSigningGrantStore.decision(
				scope: .signAndQueueUpdates, certificateUUID: certificateUUID
			)
			policy = effectivePolicy(preferred: policy, fromBackground: fromBackground, decision: decision)
			if policy != .signAndQueue {
				FileLogger.log("Scheduled signing skipped: \(decision.explanation)", category: "update")
			}
		}
		let sources = storage.getSources()

		// 1. Refresh repositories.
		if !sources.isEmpty {
			await SourcesViewModel.shared.fetchSources(sources, refresh: true)
		}
		guard !Task.isCancelled else {
			AutomationHistoryStore.shared.record("cancelled", fromBackground: fromBackground)
			return nil
		}
		// Last-known-good catalogs remain browseable, but only configured sources
		// may participate in update matching or automated signing.
		let configuredSourceURLs = Set(sources.compactMap(\.sourceURL))
		let repositories = AppUpdateChecker.configuredRepositories(
			in: Array(SourcesViewModel.shared.sources.values),
			sourceURLs: configuredSourceURLs
		)

		// 2. Recompute the update set.
		let signedApps = storage.getSignedApps()
		let importedApps = storage.getImportedApps()
		await AppUpdateChecker.shared.precomputeAllUpdates(
			sources: repositories,
			signedApps: signedApps,
			importedApps: importedApps
		)
		guard !Task.isCancelled else {
			AutomationHistoryStore.shared.record("cancelled", fromBackground: fromBackground)
			return nil
		}

		var result = AutomationRunResult(
			refreshedSources: repositories.count,
			foundUpdates: AppUpdateChecker.shared.updateCount,
			signed: 0,
			queueAdded: 0,
			skipped: 0,
			cleanup: nil
		)

        result.githubReleaseReviews = trackedReleases.reviewable
        result.failed += trackedReleases.failed
		// 3. Sign & queue, when that policy is set.
		if policy == .signAndQueue {
            // Repository refresh suspends this actor; a manual queue may have
            // started in the meantime. Never reuse that queue's outcome counts.
            guard !UpdateAllManager.shared.isRunning else {
                AutomationHistoryStore.shared.record("busy", fromBackground: fromBackground)
                return nil
            }

            let updatePreferences = UpdateMatchingPreferences.shared
            let pending = AppUpdateChecker.shared.availableUpdates
            var tasks = UpdateAllManager.shared.makeTasks(from: pending, automaticOnly: true)
            result.skipped += max(0, result.foundUpdates - tasks.count)

            if updatePreferences.autoUpdateWifiOnly && DownloadPreferences.isOnExpensivePath {
                result.skipped += tasks.count
                tasks = []
            }

            if !updatePreferences.isAutoUpdateEnabled {
                result.skipped += tasks.count
                tasks = []
            }

			if !tasks.isEmpty {
				await UpdateAllManager.shared.run(tasks: tasks, automatic: true, unattended: fromBackground)
				result.failed += UpdateAllManager.shared.failed
				result.signed = UpdateAllManager.shared.succeeded
				result.queueAdded = updatePreferences.autoInstallAfterUpdate
					? UpdateAllManager.shared.tasks.filter { $0.state == .finished }.count
					: 0
				result.skipped += UpdateAllManager.shared.tasks.filter { $0.state == .skipped }.count
			}
		}
		guard !Task.isCancelled else {
			AutomationHistoryStore.shared.record("cancelled", fromBackground: fromBackground, result: result, duration: Date().timeIntervalSince(startedAt))
			return nil
		}

		guard !Task.isCancelled else { return nil }
        // 4. Free Apple ID profile expiry check (if signed in). Discovery only — see
        // `trackExpiringFreeAppleIDProfiles`; nothing here renews or re-signs.
		await trackExpiringFreeAppleIDProfiles()
		guard !Task.isCancelled else {
			AutomationHistoryStore.shared.record("cancelled", fromBackground: fromBackground, result: result, duration: Date().timeIntervalSince(startedAt))
			return nil
		}

		guard !Task.isCancelled else { return nil }
        // 5. Run the Auto Cleanup sweep.
		result.cleanup = CleanupManager.shared.cleanNow()

		// 6. One summarizing notification.
		if fromBackground && (policy != .signAndQueue || UpdateMatchingPreferences.shared.notifyOnAutoUpdate) {
			postSummary(result)
		}

		AutomationHistoryStore.shared.record(result.failed > 0 ? "partialFailure" : "completed", fromBackground: fromBackground, result: result, duration: Date().timeIntervalSince(startedAt))
		return result
	}

	/// The policy a pass actually runs with.
	///
	/// Only an unattended pass that wants to sign is affected: without an authorizing grant
	/// it falls back to notifying. Nothing here can turn a notify-only pass into a signing one.
	nonisolated static func effectivePolicy(
		preferred: BackgroundAutomationPolicy,
		fromBackground: Bool,
		decision: UnattendedSigningGrant.Decision
	) -> BackgroundAutomationPolicy {
		guard preferred == .signAndQueue, fromBackground else { return preferred }
		return decision.isAuthorized ? .signAndQueue : .notifyOnly
	}

	/// Refreshes the expiring-profile *list* for a free Apple ID session.
	///
	/// It does not renew: the name `renewFreeAppleIDProfiles` claimed the scheduled task
	/// performed an account mutation, which it never did and must not do without an explicit
	/// user grant. The UI reads `renewalCandidates` and tells the user to renew by hand.
	private static func trackExpiringFreeAppleIDProfiles() async {
		let manager = NativeSigningManager.shared
		guard manager.isBackendReady else { return }
		await manager.refreshRenewalCandidates()
	}

	private nonisolated static func postSummary(_ result: AutomationRunResult) {
		let content = UNMutableNotificationContent()
		content.title = .localized("VexSign automation")
		content.sound = .default
		content.interruptionLevel = .active

		var lines: [String] = []
		if result.foundUpdates > 0 {
			lines.append(String.localized("%lld updates found", arguments: result.foundUpdates))
		} else {
			lines.append(.localized("No updates"))
		}
        if result.githubReleaseReviews > 0 {
            lines.append(String.localized("%lld GitHub releases need review", arguments: result.githubReleaseReviews))
        }
		if result.signed > 0 {
			if result.queueAdded == result.signed {
				lines.append(String.localized("%lld signed and queued", arguments: result.signed))
			} else if result.queueAdded > 0 {
				lines.append(String.localized("%lld signed; %lld queued", arguments: result.signed, result.queueAdded))
			} else {
				lines.append(String.localized("%lld signed; automatic install queueing is off", arguments: result.signed))
			}
		}
        if result.failed > 0 {
            lines.append(String.localized("%lld failed", arguments: result.failed))
        }
		if result.skipped > 0 {
			lines.append(String.localized("%lld skipped", arguments: result.skipped))
		}
		if let cleanup = result.cleanup, !cleanup.isIdle {
			lines.append(String.localized("Cleaned %@", arguments: cleanup.freedBytes.formattedFileSize))
		}

		content.body = lines.joined(separator: " · ")

		UNUserNotificationCenter.current().add(
			UNNotificationRequest(identifier: "vexsign.automation.\(UUID().uuidString)", content: content, trigger: nil)
		)
	}
}
