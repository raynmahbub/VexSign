//
//  AppLockSettingsView.swift
//  VexSign
//
//  Settings for the optional App Lock. Enabling requires one successful
//  authentication so a stranger can't switch the lock on as a prank (and so the
//  user finds out immediately if their device can't support it).
//

import SwiftUI
import NimbleViews
import LocalAuthentication
import NimbleExtensions

struct AppLockSettingsView: View {
	@AppStorage(AppLockManager.enabledKey)
	private var _enabled = false

	@ObservedObject private var lock = AppLockManager.shared

	private var biometryLabel: String {
		if let biometry = AppLockManager.biometryName {
			return String.localized("Use %@", arguments: biometry)
		}
		return String.localized("Require Device Passcode")
	}

	var body: some View {
		NBList(.localized("App Lock")) {
			NBSection(.localized("Protection")) {
				Toggle(isOn: Binding(
					get: { _enabled },
					set: { _setEnabled($0) }
				)) {
					Label(biometryLabel, systemImage: "faceid")
				}

				if _enabled {
					Button {
						lock.lockIfNeeded()
						lock.authenticate()
					} label: {
						Label(.localized("Lock Now"), systemImage: "lock.fill")
					}
				}
			} footer: {
				Text(.localized("Locks VexSign whenever it leaves the foreground, and on launch. Unlock with Face ID, Touch ID or the device passcode. If the device has no passcode, App Lock turns itself off instead of locking you out."))
			}
		}
		.navigationBarTitleDisplayMode(.inline)
	}

	private func _setEnabled(_ newValue: Bool) {
		if !newValue {
			_enabled = false
			return
		}

		let context = LAContext()
		var error: NSError?
		guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
			Toast.error(error?.localizedDescription ?? .localized("No device passcode is set, so App Lock cannot run."))
			_enabled = false
			return
		}

		context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String.localized("Enable App Lock")) { success, _ in
			DispatchQueue.main.async {
				if success {
					_enabled = true
					Toast.success(.localized("App Lock enabled"))
				} else {
					_enabled = false
					Toast.error(.localized("App Lock was not enabled"))
				}
			}
		}
	}
}
