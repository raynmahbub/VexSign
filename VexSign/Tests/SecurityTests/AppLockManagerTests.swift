//
//  AppLockManagerTests.swift
//  VexSignTests
//
//  The vault decides what a locked or hidden app means. Its dependencies are all
//  injected — `defaults`, the two-closure `VaultStorage`, and the `PolicyEvaluator`
//  — so its state machine can be driven here without Keychain, biometrics or a
//  running app. Until now nothing exercised it, and a regression in it either
//  leaks a concealed app or locks the owner out.
//

import Security
import XCTest
@testable import VexSign

@MainActor
final class AppLockManagerTests: XCTestCase {

	/// Stands in for the Keychain: one blob, read and written through closures.
	private final class MemoryVault {
		var blob: Data?
		var written: [Data] = []
	}

	private var defaults: UserDefaults!
	private var suiteName: String!
	private var vault: MemoryVault!

	override func setUp() {
		super.setUp()
		suiteName = "AppLockManagerTests-\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
		vault = MemoryVault()
	}

	override func tearDown() {
		defaults.removePersistentDomain(forName: suiteName)
		defaults = nil
		vault = nil
		super.tearDown()
	}

	private func storage(_ vault: MemoryVault) -> AppLockManager.VaultStorage {
		AppLockManager.VaultStorage(
			read: { vault.blob },
			write: { data in
				vault.blob = data
				vault.written.append(data)
			}
		)
	}

	/// Calls back synchronously with the answer, which is how a device that *can*
	/// evaluate a policy behaves.
	private static func evaluator(grants: Bool, calls: @escaping (Int) -> Void = { _ in }) -> AppLockManager.PolicyEvaluator {
		{ _, completion in
			calls(1)
			completion(grants, grants ? nil : NSError(domain: "test", code: 1, userInfo: [
				NSLocalizedDescriptionKey: "Denied for the test"
			]))
			return true
		}
	}

	/// A device with no passcode configured: the policy cannot be evaluated at all.
	private static let unavailableEvaluator: AppLockManager.PolicyEvaluator = { _, _ in false }

	private func storedState() throws -> AppLockManager.VaultState {
		let data = try XCTUnwrap(vault.blob)
		return try JSONDecoder().decode(AppLockManager.VaultState.self, from: data)
	}

	// MARK: - Loading

	func testStoredStateIsPublishedOnInit() throws {
		vault.blob = try JSONEncoder().encode(AppLockManager.VaultState(
			enabled: true,
			lockedAppUUIDs: ["locked"],
			hiddenAppUUIDs: ["vaulted"],
			strictHidingEnabled: true
		))

		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: true))

		XCTAssertTrue(manager.isMasterLockEnabled)
		XCTAssertTrue(manager.isLocked, "a locked app that launches already locked must not render its library")
		XCTAssertEqual(manager.lockedAppUUIDs, ["locked"])
		XCTAssertEqual(manager.hiddenAppUUIDs, ["vaulted"])
		XCTAssertTrue(manager.strictHidingEnabled)
	}

	func testLegacyDefaultsAreMigratedAndCleared() throws {
		defaults.set(true, forKey: AppLockManager.enabledKey)
		defaults.set(true, forKey: AppLockManager.strictHidingKey)

		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: true))

		XCTAssertTrue(manager.isMasterLockEnabled)
		XCTAssertTrue(manager.strictHidingEnabled)
		XCTAssertEqual(try storedState().enabled, true, "the migrated state must now live in the vault")
		XCTAssertNil(defaults.object(forKey: AppLockManager.enabledKey), "the plaintext copy must not survive the migration")
		XCTAssertNil(defaults.object(forKey: AppLockManager.strictHidingKey))
	}

	func testAnUnreadableVaultFallsBackWithoutDiscardingLegacyValues() {
		defaults.set(true, forKey: AppLockManager.enabledKey)
		let unreadable = AppLockManager.VaultStorage(
			read: { throw SecureSecretStore.Failure(status: errSecNotAvailable) },
			write: { _ in throw SecureSecretStore.Failure(status: errSecNotAvailable) }
		)

		let manager = AppLockManager(defaults: defaults, storage: unreadable, evaluator: Self.evaluator(grants: true))

		XCTAssertTrue(manager.isMasterLockEnabled)
		XCTAssertNotNil(defaults.object(forKey: AppLockManager.enabledKey),
		                "a failed write must not lose the only copy of the setting")
	}

	// MARK: - Hiding

	func testHidingAnAppPersistsAndHidesItFromAutomation() throws {
		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: true))
		manager.toggleHideApp("vaulted")

		XCTAssertTrue(manager.isAppHidden("vaulted"))
		XCTAssertFalse(AutomationVisibility.isVisible(uuid: "vaulted", hiddenAppUUIDs: manager.hiddenAppUUIDs),
		               "a hidden app must not be named by the Web Manager or Shortcuts")
		XCTAssertEqual(try storedState().hiddenAppUUIDs, ["vaulted"])
	}

	func testUnhidingAsksTheGateAndADenialKeepsItHidden() {
		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: true))
		manager.toggleHideApp("vaulted")

		let denied = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: false))
		denied.toggleHideApp("vaulted")
		XCTAssertTrue(denied.hiddenAppUUIDs.contains("vaulted"), "a refused authentication must not reveal the app")
	}

	func testGrantedAuthenticationUnhides() {
		var prompts = 0
		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: true) { _ in prompts += 1 })
		manager.toggleHideApp("vaulted")
		manager.toggleHideApp("vaulted")

		XCTAssertFalse(manager.isAppHidden("vaulted"))
		XCTAssertEqual(prompts, 1, "the reveal must have asked exactly once")
	}

	func testRevealSessionHidesNothingOnItsOwn() {
		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: true))
		manager.toggleHideApp("vaulted")
		XCTAssertFalse(manager.isStrictlyHidden("vaulted"), "hiding a row is not strict mode")
		manager.strictHidingEnabled = true
		XCTAssertTrue(manager.isStrictlyHidden("vaulted"))
	}

	// MARK: - Strict mode

	func testDisablingStrictHidingNeedsTheGate() {
		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: false))
		manager.strictHidingEnabled = true
		manager.strictHidingEnabled = false

		XCTAssertTrue(manager.strictHidingEnabled, "a denied prompt must leave strict hiding on")
	}

	func testGrantedPromptDisablesStrictHiding() throws {
		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: true))
		manager.strictHidingEnabled = true
		manager.strictHidingEnabled = false

		XCTAssertFalse(manager.strictHidingEnabled)
		XCTAssertFalse(try storedState().strictHidingEnabled)
	}

	func testADeviceWithoutAPasscodeCanStillTurnStrictHidingOff() {
		// Nothing can be protected without a passcode, so refusing the change would
		// only trap the setting in a state the owner cannot undo.
		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.unavailableEvaluator)
		manager.strictHidingEnabled = true
		manager.strictHidingEnabled = false

		XCTAssertFalse(manager.strictHidingEnabled)
	}

	// MARK: - Locking

	func testLockingClearsTheSessionAndTheReveal() throws {
		vault.blob = try JSONEncoder().encode(AppLockManager.VaultState(
			enabled: true,
			lockedAppUUIDs: ["locked"],
			hiddenAppUUIDs: [],
			strictHidingEnabled: false
		))
		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: true))
		XCTAssertTrue(manager.isLocked, "precondition: a launch with the lock on starts covered")

		manager.authenticate()
		XCTAssertFalse(manager.isLocked)

		var granted = false
		manager.authenticateForApp(uuid: "locked", name: "Locked") { granted = $0 }
		XCTAssertTrue(granted)
		XCTAssertTrue(manager.isSessionUnlocked("locked"))

		manager.isRevealingHiddenApps = true
		manager.lockIfNeeded()

		XCTAssertTrue(manager.isLocked)
		XCTAssertFalse(manager.isSessionUnlocked("locked"), "a new lock starts with no per-app session")
		XCTAssertFalse(manager.isRevealingHiddenApps)
	}

	func testLockingIsANoOpWhileTheMasterLockIsOff() {
		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: true))
		manager.lockIfNeeded()
		XCTAssertFalse(manager.isLocked)
	}

	// MARK: - Policy

	func testStrictHidingIsMirroredWithoutTheRevealSession() {
		let manager = AppLockManager(defaults: defaults, storage: storage(vault), evaluator: Self.evaluator(grants: true))
		manager.toggleHideApp("vaulted")
		manager.strictHidingEnabled = true

		XCTAssertTrue(StrictHidingSnapshot.shared.hides("vaulted"),
		              "the widget payload and the backup writer read the mirror")

		manager.isRevealingHiddenApps = true
		XCTAssertTrue(StrictHidingSnapshot.shared.hides("vaulted"),
		              "revealing the vault on screen must not hand the app to a widget or a backup file")
	}
}
