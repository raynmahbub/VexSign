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
	static let shared = AppLockManager()

	static let enabledKey = "VexSign.security.appLockEnabled"
	private static let lockedAppsKey = "VexSign.security.lockedAppUUIDs"
	private static let hiddenAppsKey = "VexSign.security.hiddenAppUUIDs"
	static let strictHidingKey = "VexSign.security.strictHiding"

	/// True while the master lock overlay should cover the UI.
	@Published private(set) var isLocked: Bool
	@Published private(set) var isAuthenticating = false
	@Published private(set) var lastMessage: String?

	// MARK: - Specific App Lock & Hidden Apps Vault
	@Published var lockedAppUUIDs: Set<String> {
		didSet {
			UserDefaults.standard.set(Array(lockedAppUUIDs), forKey: Self.lockedAppsKey)
		}
	}

	@Published var hiddenAppUUIDs: Set<String> {
		didSet {
			UserDefaults.standard.set(Array(hiddenAppUUIDs), forKey: Self.hiddenAppsKey)
		}
	}

	/// When true, hidden apps are shown in Library (requires biometric authentication)
	@Published var isRevealingHiddenApps = false

	/// Strict mode also removes hidden apps from counts and app-facing discovery
	/// surfaces instead of only hiding their Library rows.
	@Published var strictHidingEnabled: Bool {
		didSet { UserDefaults.standard.set(strictHidingEnabled, forKey: Self.strictHidingKey) }
	}

	/// Set of app UUIDs that were authenticated this session so user isn't prompted repeatedly
	private var sessionUnlockedUUIDs: Set<String> = []

	private init() {
		isLocked = UserDefaults.standard.bool(forKey: Self.enabledKey)

		let savedLocked = UserDefaults.standard.stringArray(forKey: Self.lockedAppsKey) ?? []
		self.lockedAppUUIDs = Set(savedLocked)

		let savedHidden = UserDefaults.standard.stringArray(forKey: Self.hiddenAppsKey) ?? []
		self.hiddenAppUUIDs = Set(savedHidden)
		self.strictHidingEnabled = UserDefaults.standard.bool(forKey: Self.strictHidingKey)
	}

	static var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: enabledKey)
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
	func lockIfNeeded() {
		guard Self.isEnabled, !isLocked, !isAuthenticating else { return }
		isLocked = true
		sessionUnlockedUUIDs.removeAll()
		isRevealingHiddenApps = false
	}

	func authenticateIfNeeded() {
		guard Self.isEnabled, isLocked else { return }
		authenticate()
	}

	func authenticate() {
		guard !isAuthenticating else { return }

		let context = LAContext()
		context.localizedCancelTitle = String.localized("Cancel")

		var error: NSError?
		guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
			UserDefaults.standard.set(false, forKey: Self.enabledKey)
			lastMessage = error?.localizedDescription ?? String.localized("No device passcode is set, so App Lock cannot run.")
			isLocked = false
			return
		}

		isAuthenticating = true
		context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String.localized("Unlock VexSign")) { [weak self] success, authError in
			DispatchQueue.main.async {
				guard let self else { return }
				self.isAuthenticating = false
				if success {
					self.isLocked = false
					self.lastMessage = nil
				} else {
					self.lastMessage = authError?.localizedDescription
				}
			}
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
			lockedAppUUIDs.remove(uuid)
			sessionUnlockedUUIDs.remove(uuid)
		} else {
			lockedAppUUIDs.insert(uuid)
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

		let context = LAContext()
		context.localizedCancelTitle = String.localized("Cancel")

		var error: NSError?
		guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
			// If device has no passcode, allow access
			completion(true)
			return
		}

		let reason = String.localized("Unlock %@", arguments: name)
		context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, _ in
			DispatchQueue.main.async {
				if success {
					self?.sessionUnlockedUUIDs.insert(uuid)
					completion(true)
				} else {
					completion(false)
				}
			}
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
			hiddenAppUUIDs.remove(uuid)
		} else {
			hiddenAppUUIDs.insert(uuid)
		}
	}

	func authenticateToRevealHidden(completion: @escaping (Bool) -> Void) {
		if isRevealingHiddenApps {
			// Toggle off without prompt
			isRevealingHiddenApps = false
			completion(false)
			return
		}

		let context = LAContext()
		context.localizedCancelTitle = String.localized("Cancel")

		var error: NSError?
		guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
			isRevealingHiddenApps = true
			completion(true)
			return
		}

		context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String.localized("Reveal Hidden Applications")) { [weak self] success, _ in
			DispatchQueue.main.async {
				if success {
					self?.isRevealingHiddenApps = true
					completion(true)
				} else {
					completion(false)
				}
			}
		}
	}

	func hideHiddenApps() {
		isRevealingHiddenApps = false
	}
}
