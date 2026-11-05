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

        #expect(BackgroundAutomationPreferences.isEnabled == false)
        #expect(BackgroundAutomationPreferences.policy == .notifyOnly)
    }

    @Test("BackgroundAutomationPreferences can be set")
    func testSetPreferences() {
        BackgroundAutomationPreferences.isEnabled = true
        BackgroundAutomationPreferences.policy = .signAndQueue

        #expect(BackgroundAutomationPreferences.isEnabled == true)
        #expect(BackgroundAutomationPreferences.policy == .signAndQueue)

        // Reset
        BackgroundAutomationPreferences.isEnabled = false
        BackgroundAutomationPreferences.policy = .notifyOnly
    }

    @Test("BackgroundAutomationPolicy localized descriptions")
    func testPolicyDescriptions() {
        #expect(BackgroundAutomationPolicy.notifyOnly.localizedDescription == .localized("Notify only"))
        #expect(BackgroundAutomationPolicy.signAndQueue.localizedDescription == .localized("Sign & queue"))

        #expect(BackgroundAutomationPolicy.notifyOnly.localizedDetail.contains("Nothing is signed or downloaded"))
        #expect(BackgroundAutomationPolicy.signAndQueue.localizedDetail.contains("Sign & queue"))
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