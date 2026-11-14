// MARK: - BackgroundAutomationTests
/// Unit tests for the BackgroundAutomation functionality.

import Foundation
import Testing
import NimbleExtensions
@testable import VexSign

/// `AutomationHistoryStore` is main-actor isolated, and Swift Testing does not run suites
/// on the main actor unless the suite says so.
@MainActor
@Suite("BackgroundAutomation Tests")
struct BackgroundAutomationTests {

    // MARK: - Preferences Tests

    @Test("BackgroundAutomationPreferences default values")
    func testDefaultPreferences() {
        // Reset to defaults
        UserDefaults.standard.removeObject(forKey: "VexSign.automation.enabled")
        UserDefaults.standard.removeObject(forKey: "VexSign.automation.policy")
        UserDefaults.standard.removeObject(forKey: BackgroundAutomationPreferences.intervalKey)

        #expect(BackgroundAutomationPreferences.isEnabled == false)
        #expect(BackgroundAutomationPreferences.policy == .notifyOnly)
        #expect(BackgroundAutomationPreferences.interval == .everySixHours)
    }

    @Test("BackgroundAutomationPreferences can be set")
    func testSetPreferences() {
        BackgroundAutomationPreferences.isEnabled = true
        BackgroundAutomationPreferences.policy = .signAndQueue
        BackgroundAutomationPreferences.interval = .hourly

        #expect(BackgroundAutomationPreferences.isEnabled == true)
        #expect(BackgroundAutomationPreferences.policy == .signAndQueue)
        #expect(BackgroundAutomationPreferences.interval == .hourly)
        #expect(BackgroundAutomationInterval.allCases.map(\.rawValue) == [3_600, 10_800, 21_600, 43_200, 86_400])

        // Reset
        BackgroundAutomationPreferences.isEnabled = false
        BackgroundAutomationPreferences.policy = .notifyOnly
        BackgroundAutomationPreferences.interval = .everySixHours
    }

    @Test("BackgroundAutomationPolicy localized descriptions")
    func testPolicyDescriptions() {
        #expect(BackgroundAutomationPolicy.notifyOnly.localizedDescription == .localized("Notify only"))
        #expect(BackgroundAutomationPolicy.signAndQueue.localizedDescription == .localized("Sign & queue"))

        #expect(BackgroundAutomationPolicy.notifyOnly.localizedDetail.contains("Nothing is signed or downloaded"))
        #expect(BackgroundAutomationPolicy.signAndQueue.localizedDetail.contains("install queue"))
    }

    @Test("Per-app automatic updates can explicitly opt out from the all-apps default")
    func testAutomaticUpdateAllowlist() {
        let preferences = UpdateMatchingPreferences.shared
        let oldActive = preferences.autoUpdateAllowlistActive
        let oldApps = preferences.autoUpdateAppUUIDs
        let oldMode = preferences.matchingMode
        let oldFavorites = preferences.favoriteAppUUIDs
        defer {
            preferences.autoUpdateAppUUIDs = oldApps
            preferences.autoUpdateAllowlistActive = oldActive
            preferences.matchingMode = oldMode
            preferences.favoriteAppUUIDs = oldFavorites
        }

        preferences.matchingMode = .allApps
        preferences.autoUpdateAllowlistActive = false
        preferences.autoUpdateAppUUIDs = []
        #expect(preferences.isAutoUpdateAllowed(for: "app-a"))

        preferences.toggleAutoUpdate(for: "app-a", allUUIDs: ["app-a", "app-b"])
        #expect(preferences.autoUpdateAllowlistActive)
        #expect(!preferences.isAutoUpdateAllowed(for: "app-a"))
        #expect(preferences.isAutoUpdateAllowed(for: "app-b"))

        preferences.toggleAutoUpdate(for: "app-b", allUUIDs: ["app-a", "app-b"])
        #expect(!preferences.isAutoUpdateAllowed(for: "app-b"))
        preferences.autoUpdateAppUUIDs = []
        #expect(!preferences.isAutoUpdateAllowed(for: "app-a"))

        preferences.autoUpdateAllowlistActive = false
        preferences.matchingMode = .favoritesOnly
        preferences.favoriteAppUUIDs = ["favorite-app"]
        #expect(preferences.isAutoUpdateAllowed(for: "favorite-app"))
        #expect(!preferences.isAutoUpdateAllowed(for: "other-app"))
    }

    @Test("Automatic update source pause persists and is removed with its source")
    func testSourceAutomaticUpdatePreference() {
        let sourceID = "test-auto-update-source-\(UUID().uuidString)"
        let urlAlias = "https://example.invalid/\(UUID().uuidString).json"
        defer {
            SourcePreferences.setAutoUpdatesEnabled(true, for: sourceID)
            SourcePreferences.setAutoUpdatesEnabled(true, for: urlAlias)
        }

        #expect(SourcePreferences.autoUpdatesEnabled(for: sourceID))
        SourcePreferences.setAutoUpdatesEnabled(false, for: sourceID)
        #expect(!SourcePreferences.autoUpdatesEnabled(for: sourceID))
        SourcePreferences.setAutoUpdatesEnabled(true, for: sourceID)
        #expect(SourcePreferences.autoUpdatesEnabled(for: sourceID))

        SourcePreferences.setAutoUpdatesEnabled(false, for: urlAlias)
        SourcePreferences.removeAllData(for: sourceID, automaticUpdateAlias: urlAlias)
        #expect(SourcePreferences.autoUpdatesEnabled(for: urlAlias))
    }

    // MARK: - AutomationRunResult Tests

    @Test("AutomationRunResult initialization")
    func testRunResultInitialization() {
        let result = AutomationRunResult(
            refreshedSources: 3,
            foundUpdates: 5,
            signed: 2,
            queueAdded: 2,
            skipped: 1,
            cleanup: nil,
            failed: 0
        )

        #expect(result.refreshedSources == 3)
        #expect(result.foundUpdates == 5)
        #expect(result.signed == 2)
        #expect(result.queueAdded == 2)
        #expect(result.skipped == 1)
        #expect(result.failed == 0)
    }

    // MARK: - AutomationHistoryStore Tests

    @Test("AutomationHistoryStore records history")
    func testHistoryStoreRecords() {
        let store = AutomationHistoryStore.shared
        let initialCount = store.entries.count

        let result = AutomationRunResult(
            refreshedSources: 2,
            foundUpdates: 3,
            signed: 1,
            queueAdded: 1,
            skipped: 0,
            cleanup: nil,
            failed: 0
        )

        store.record("completed", fromBackground: true, result: result, duration: 30.0)

        #expect(store.entries.count == initialCount + 1)
        #expect(store.entries.first?.outcome == "completed")
        #expect(store.entries.first?.fromBackground == true)
        #expect(store.entries.first?.updates == 3)
        #expect(store.entries.first?.signed == 1)

        // Cleanup
        store.clear()
    }

    @Test("AutomationHistoryStore limits to 50 entries")
    func testHistoryStoreLimit() {
        let store = AutomationHistoryStore.shared
        store.clear()

        let result = AutomationRunResult(
            refreshedSources: 1,
            foundUpdates: 1,
            signed: 0,
            queueAdded: 0,
            skipped: 0,
            cleanup: nil,
            failed: 0
        )

        // Add 60 entries
        for i in 0..<60 {
            store.record("test\(i)", fromBackground: false, result: result)
        }

        #expect(store.entries.count == 50)

        // Cleanup
        store.clear()
    }
}