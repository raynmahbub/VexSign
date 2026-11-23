//
//  AppLockManager.swift
//  VexSign
//
//  Enhanced App Lock & Privacy Manager featuring:
//  - Master App Lock (Face ID / Touch ID / Passcode)
//  - Specific App Lock (Per-app biometric protection)
//  - Hidden Apps Vault (Conceal apps behind Face ID authentication)
//

import Foundation
import LocalAuthentication
import SwiftUI
import NimbleExtensions

@MainActor
final class AppLockManager: ObservableObject {
	struct VaultState: Codable, Equatable {
		var enabled: Bool = false
		var lockedAppUUIDs: Set<String> = []
		var hiddenAppUUIDs: Set<String> = []
		var strictHidingEnabled: Bool = false
	}

	struct VaultStorage {
		var read: () throws -> Data?
		var write: (Data) throws -> Void

		static let keychain = VaultStorage(
			read: { try SecureSecretStore.read(AppLockManager.vaultAccount, service: AppLockManager.vaultService) },
			write: { try SecureSecretStore.write($0, account: AppLockManager.vaultAccount, service: AppLockManager.vaultService) }
		)
	}

	/// Evaluates device-owner authentication. Returns `false` synchronously when the
	/// device cannot evaluate `.deviceOwnerAuthentication` (no passcode configured);
	/// otherwise invokes the completion handler on the main queue and returns `true`.
	typealias PolicyEvaluator = (_ localizedReason: String, _ completion: @escaping (Bool, Error?) -> Void) -> Bool

	static let shared = AppLockManager()

	static let enabledKey = "VexSign.security.appLockEnabled"
	private static let lockedAppsKey = "VexSign.security.lockedAppUUIDs"
	private static let hiddenAppsKey = "VexSign.security.hiddenAppUUIDs"
	static let strictHidingKey = "VexSign.security.strictHiding"
	private static let vaultService = "com.vexsign.security.applock"
	private static let vaultAccount = "appLock.vaultState.v1"

	/// True while the master lock overlay should cover the UI.
	@Published private(set) var isLocked: Bool
	@Published private(set) var isMasterLockEnabled: Bool
	@Published private(set) var isAuthenticating = false
	@Published private(set) var lastMessage: String?

	// MARK: - Specific App Lock & Hidden Apps Vault
	@Published private(set) var lockedAppUUIDs: Set<String>
	@Published private(set) var hiddenAppUUIDs: Set<String>

	/// When true, hidden apps are shown in Library (requires biometric authentication)
	@Published var isRevealingHiddenApps = false

	/// Strict mode also removes hidden apps from counts and app-facing discovery
	/// surfaces instead of only hiding their Library rows. Disabling requires
	/// either an unlocked Hidden Vault session or fresh biometric/passcode verification.
	@Published var strictHidingEnabled: Bool {
		didSet {
			guard !_suppressDidSet else { return }
			if !strictHidingEnabled && oldValue && !isRevealingHiddenApps {
				_suppressDidSet = true
				strictHidingEnabled = true
				_suppressDidSet = false
				_evaluateGate(reason: String.localized("Reveal Hidden Applications"), allowWithoutPasscode: true) { [weak self] granted in
					guard let self, granted else { return }
					self._suppressDidSet = true
					self.strictHidingEnabled = false
					self._suppressDidSet = false
					self._persistState()
				}
				return
			}
			_persistState()
		}
	}

	/// Set of app UUIDs that were authenticated this session so user isn't prompted repeatedly
	private var sessionUnlockedUUIDs: Set<String> = []
	private let _storage: VaultStorage
	private let _evaluator: PolicyEvaluator
	private var _suppressDidSet = false

	init(
		defaults: UserDefaults = .standard,
		storage: VaultStorage = .keychain,
		evaluator: @escaping PolicyEvaluator = AppLockManager.defaultPolicyEvaluator
	) {
		self._storage = storage
		self._evaluator = evaluator

		let state = Self._loadOrMigrateState(defaults: defaults, storage: storage)
		self.isMasterLockEnabled = state.enabled
		self.isLocked = state.enabled
		self.lockedAppUUIDs = state.lockedAppUUIDs
		self.hiddenAppUUIDs = state.hiddenAppUUIDs
		self.strictHidingEnabled = state.strictHidingEnabled
		_publishStrictSnapshot()
	}

	private static func _loadOrMigrateState(defaults: UserDefaults, storage: VaultStorage) -> VaultState {
		do {
			if let existing = try storage.read() {
				let decoded = try JSONDecoder().decode(VaultState.self, from: existing)
				_clearLegacyDefaults(defaults)
				return decoded
			}
		} catch {
			// Fall back to legacy defaults without deleting them when Keychain is unreadable.
		}

		let hasLegacy =
			defaults.object(forKey: enabledKey) != nil
			|| defaults.object(forKey: lockedAppsKey) != nil
			|| defaults.object(forKey: hiddenAppsKey) != nil
			|| defaults.object(forKey: strictHidingKey) != nil

		let legacy = VaultState(
			enabled: defaults.bool(forKey: enabledKey),
			lockedAppUUIDs: Set(defaults.stringArray(forKey: lockedAppsKey) ?? []),
			hiddenAppUUIDs: Set(defaults.stringArray(forKey: hiddenAppsKey) ?? []),
			strictHidingEnabled: defaults.bool(forKey: strictHidingKey)
		)

		if hasLegacy {
			do {
				let encoded = try JSONEncoder().encode(legacy)
				try storage.write(encoded)
				_clearLegacyDefaults(defaults)
			} catch {
				// Keep legacy values in place if the initial Keychain write fails.
			}
		}
		return legacy
	}

	private static func _clearLegacyDefaults(_ defaults: UserDefaults) {
		defaults.removeObject(forKey: enabledKey)
		defaults.removeObject(forKey: lockedAppsKey)
		defaults.removeObject(forKey: hiddenAppsKey)
		defaults.removeObject(forKey: strictHidingKey)
	}

	private func _persistState() {
		_publishStrictSnapshot()
		let state = VaultState(
			enabled: isMasterLockEnabled,
			lockedAppUUIDs: lockedAppUUIDs,
			hiddenAppUUIDs: hiddenAppUUIDs,
			strictHidingEnabled: strictHidingEnabled
		)
		do {
			let data = try JSONEncoder().encode(state)
			try _storage.write(data)
		} catch {
			lastMessage = error.localizedDescription
		}
	}

	/// Mirrors the vault into `StrictHidingSnapshot` for the surfaces that are not
	/// views (the widget payload and the backup writer). Strict-ness is mirrored
	/// without `isRevealingHiddenApps`: an open vault shows rows on screen, it does
	/// not licence a Home Screen tile or an exported backup to name hidden apps.
	private func _publishStrictSnapshot() {
		StrictHidingSnapshot.shared.update(
			isEnabled: strictHidingEnabled,
			hiddenAppUUIDs: hiddenAppUUIDs
		)
	}

	static func defaultPolicyEvaluator(_ localizedReason: String, completion: @escaping (Bool, Error?) -> Void) -> Bool {
		let context = LAContext()
		context.localizedCancelTitle = String.localized("Cancel")
		var error: NSError?
		guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
			return false
		}
		context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: localizedReason) { success, authError in
			DispatchQueue.main.async {
				completion(success, authError)
			}
		}
		return true
	}

	private func _evaluateGate(
		reason: String,
		allowWithoutPasscode: Bool,
		completion: @escaping (Bool) -> Void
	) {
		var evaluatedSynchronously = false
		let canEvaluate = _evaluator(reason) { [weak self] success, authError in
			evaluatedSynchronously = true
			if !success {
				self?.lastMessage = authError?.localizedDescription
			}
			completion(success)
		}
		if !canEvaluate && !evaluatedSynchronously {
			completion(allowWithoutPasscode)
		}
	}

	static var isEnabled: Bool {
		shared.isMasterLockEnabled
	}

	/// "Face ID" / "Touch ID" for labels, or nil when only the passcode is available.
	static var biometryName: String? {
		let context = LAContext()
		var error: NSError?
		guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
		switch context.biometryType {
		case .faceID: return String.localized("Face ID")
		case .touchID: return String.localized("Touch ID")
		default: return nil
		}
	}

	// MARK: - Master App Lock
	func setMasterLockEnabled(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
		if enabled == isMasterLockEnabled {
			completion?(true)
			return
		}
		let reason = enabled ? String.localized("Enable App Lock") : String.localized("Unlock VexSign")
		// Enabling requires a device passcode (`allowWithoutPasscode: false`);
		// disabling when the user removed their device passcode is permitted so they are not locked out.
		_evaluateGate(reason: reason, allowWithoutPasscode: !enabled) { [weak self] granted in
			guard let self else {
				completion?(false)
				return
			}
			guard granted else {
				completion?(false)
				return
			}
			self.isMasterLockEnabled = enabled
			if !enabled {
				self.isLocked = false
			}
			self._persistState()
			completion?(true)
		}
	}

	func lockIfNeeded() {
		guard isMasterLockEnabled, !isLocked, !isAuthenticating else { return }
		isLocked = true
		sessionUnlockedUUIDs.removeAll()
		isRevealingHiddenApps = false
	}

	func authenticateIfNeeded() {
		guard isMasterLockEnabled, isLocked else { return }
		authenticate()
	}

	func authenticate() {
		guard !isAuthenticating else { return }

		isAuthenticating = true
		let canEvaluate = _evaluator(String.localized("Unlock VexSign")) { [weak self] success, authError in
			guard let self else { return }
			self.isAuthenticating = false
			if success {
				self.isLocked = false
				self.lastMessage = nil
			} else {
				self.lastMessage = authError?.localizedDescription
			}
		}

		if !canEvaluate {
			isAuthenticating = false
			isMasterLockEnabled = false
			isLocked = false
			lastMessage = String.localized("No device passcode is set, so App Lock cannot run.")
			_persistState()
		}
	}

	// MARK: - Specific App Lock
	func isAppLocked(_ uuid: String) -> Bool {
		lockedAppUUIDs.contains(uuid)
	}

	func isSessionUnlocked(_ uuid: String) -> Bool {
		sessionUnlockedUUIDs.contains(uuid)
	}

	func toggleAppLock(_ uuid: String) {
		if lockedAppUUIDs.contains(uuid) {
			if sessionUnlockedUUIDs.contains(uuid) {
				lockedAppUUIDs.remove(uuid)
				sessionUnlockedUUIDs.remove(uuid)
				_persistState()
				return
			}
			_evaluateGate(reason: String.localized("Unlock VexSign"), allowWithoutPasscode: true) { [weak self] granted in
				guard let self, granted else { return }
				self.lockedAppUUIDs.remove(uuid)
				self.sessionUnlockedUUIDs.remove(uuid)
				self._persistState()
			}
		} else {
			lockedAppUUIDs.insert(uuid)
			_persistState()
		}
	}

	func authenticateForApp(uuid: String, name: String, completion: @escaping (Bool) -> Void) {
		// If app is not specifically locked or was already unlocked this session, pass through
		guard isAppLocked(uuid) else {
			completion(true)
			return
		}

		if sessionUnlockedUUIDs.contains(uuid) {
			completion(true)
			return
		}

		let reason = String.localized("Unlock %@", arguments: name)
		_evaluateGate(reason: reason, allowWithoutPasscode: true) { [weak self] granted in
			if granted {
				self?.sessionUnlockedUUIDs.insert(uuid)
			}
			completion(granted)
		}
	}

	// MARK: - Hidden Apps Vault
	func isAppHidden(_ uuid: String) -> Bool {
		hiddenAppUUIDs.contains(uuid)
	}

	/// Use this for Home summaries and update matching. The dedicated Hidden
	/// Apps screen intentionally uses `isAppHidden` so it can always manage
	/// concealed entries.
	func isStrictlyHidden(_ uuid: String) -> Bool {
		strictHidingEnabled && !isRevealingHiddenApps && hiddenAppUUIDs.contains(uuid)
	}

	func toggleHideApp(_ uuid: String) {
		if hiddenAppUUIDs.contains(uuid) {
			if isRevealingHiddenApps {
				hiddenAppUUIDs.remove(uuid)
				_persistState()
				return
			}
			_evaluateGate(reason: String.localized("Reveal Hidden Applications"), allowWithoutPasscode: true) { [weak self] granted in
				guard let self, granted else { return }
				self.hiddenAppUUIDs.remove(uuid)
				self._persistState()
			}
		} else {
			hiddenAppUUIDs.insert(uuid)
			_persistState()
		}
	}

	func authenticateToRevealHidden(completion: @escaping (Bool) -> Void) {
		if isRevealingHiddenApps {
			// Toggle off without prompt
			isRevealingHiddenApps = false
			completion(false)
			return
		}

		_evaluateGate(reason: String.localized("Reveal Hidden Applications"), allowWithoutPasscode: true) { [weak self] granted in
			if granted {
				self?.isRevealingHiddenApps = true
			}
			completion(granted)
		}
	}

	func hideHiddenApps() {
		isRevealingHiddenApps = false
	}
}

extension AppLockManager {
    func canOpenFixtureBackup(_ entry: FixtureRecoveryEntry) -> Bool {
        return !isLocked && [entry.uuid, entry.activeUUID].compactMap { $0 }.allSatisfy { id in
            (!hiddenAppUUIDs.contains(id) || isRevealingHiddenApps) &&
            (!isAppLocked(id) || isSessionUnlocked(id))
        }
    }
}
