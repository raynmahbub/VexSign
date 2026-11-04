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
			.localized("Checks for updates, signs every app that has one and queues the installs. You still confirm each install.")
		}
	}
}

// MARK: - Preferences
struct BackgroundAutomationPreferences {
	static let enabledKey = "VexSign.automation.enabled"
	static let policyKey = "VexSign.automation.policy"

	static var isEnabled: Bool {
		get { UserDefaults.standard.bool(forKey: enabledKey) }
		set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
	}

	static var policy: BackgroundAutomationPolicy {
		get { BackgroundAutomationPolicy(rawValue: UserDefaults.standard.string(forKey: policyKey) ?? "") ?? .notifyOnly }
		set { UserDefaults.standard.set(newValue.rawValue, forKey: policyKey) }
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
    private static var isRunning = false
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

		let policy = BackgroundAutomationPreferences.policy
		let storage = Storage.shared
		let sources = storage.getSources()
        guard !sources.isEmpty else {
            AutomationHistoryStore.shared.record("noSources", fromBackground: fromBackground)
            return nil
        }

		// 1. Refresh repositories.
		await SourcesViewModel.shared.fetchSources(sources, refresh: true)
		let repositories = Array(SourcesViewModel.shared.sources.values)

		// 2. Recompute the update set.
		let signedApps = storage.getSignedApps()
		let importedApps = storage.getImportedApps()
		await AppUpdateChecker.shared.precomputeAllUpdates(
			sources: repositories,
			signedApps: signedApps,
			importedApps: importedApps
		)

		var result = AutomationRunResult(
			refreshedSources: repositories.count,
			foundUpdates: AppUpdateChecker.shared.updateCount,
			signed: 0,
			queueAdded: 0,
			skipped: 0,
			cleanup: nil
		)

		// 3. Sign & queue, when that policy is set.
		if policy == .signAndQueue {
            // Repository refresh suspends this actor; a manual queue may have
            // started in the meantime. Never reuse that queue's outcome counts.
            guard !UpdateAllManager.shared.isRunning else {
                AutomationHistoryStore.shared.record("busy", fromBackground: fromBackground)
                return nil
            }
			let prepared = UpdateAllManager.makeTasks(
				from: repositories,
				signedApps: signedApps,
				importedApps: importedApps
			)
			let updates = prepared.filter { $0.hasUpdate }
			let tasks = UpdateAllManager.shared.makeTasks(
				from: updates.map { ($0.app, $0.sourceName, $0.hasUpdate) }
			)

			if !tasks.isEmpty {
				await UpdateAllManager.shared.run(tasks: tasks)
				result.failed = UpdateAllManager.shared.failed
				result.signed = UpdateAllManager.shared.succeeded
				result.queueAdded = UpdateAllManager.shared.tasks.filter { $0.state == .finished }.count
				result.skipped = UpdateAllManager.shared.tasks.filter { $0.state == .skipped }.count
			}
		}

		// 4. Free Apple ID profile renewal (if signed in)
		await renewFreeAppleIDProfiles()

		// 5. Run the Auto Cleanup sweep.
		result.cleanup = CleanupManager.shared.cleanNow()

		// 6. One summarizing notification.
		if fromBackground {
			postSummary(result)
		}

		AutomationHistoryStore.shared.record(result.failed > 0 ? "partialFailure" : "completed", fromBackground: fromBackground, result: result, duration: Date().timeIntervalSince(startedAt))
		return result
	}

	/// Checks for expiring free Apple ID profiles and renews them.
	/// Only runs when a free Apple ID session is active.
	private static func renewFreeAppleIDProfiles() async {
		let manager = NativeSigningManager.shared
		guard manager.isBackendReady else { return }
		await manager.renewExpiringProfiles()
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
		if result.signed > 0 {
			lines.append(String.localized("%lld signed and queued", arguments: result.signed))
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
