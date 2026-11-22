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
					get: { lock.isMasterLockEnabled },
					set: { _setEnabled($0) }
				)) {
					Label(biometryLabel, systemImage: "faceid")
				}

				if lock.isMasterLockEnabled {
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
		lock.setMasterLockEnabled(newValue) { granted in
			if granted {
				if newValue {
					Toast.success(.localized("App Lock enabled"))
				}
			} else if newValue {
				Toast.error(lock.lastMessage ?? .localized("App Lock was not enabled"))
			}
		}
	}
}
