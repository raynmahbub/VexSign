//
//  CertificateExpirySettingsView.swift
//  VexSign
//
//  Controls for CertificateExpiryMonitor: enable reminders (requesting
//  notification permission on the spot), pick how early to warn, and run a check
//  immediately.
//

import SwiftUI
import NimbleViews
import UserNotifications
import NimbleExtensions

struct CertificateExpirySettingsView: View {
	@AppStorage(CertificateExpiryMonitor.enabledKey)
	private var _enabled = false

	@AppStorage(CertificateExpiryMonitor.daysKey)
	private var _days = 14

	@State private var _checking = false

	private let _dayOptions = [3, 7, 14]

	var body: some View {
		NBList(.localized("Expiry Reminders")) {
			NBSection(.localized("Reminders")) {
				Toggle(isOn: Binding(
					get: { _enabled },
					set: { _setEnabled($0) }
				)) {
					Label(.localized("Enable Reminders"), systemImage: "bell.badge")
				}

				if _enabled {
					Picker(.localized("Warn Me"), selection: $_days) {
						ForEach(_dayOptions, id: \.self) { days in
							Text(verbatim: .localized("%lld Days Before Expiry", arguments: days)).tag(days)
						}
					}

					Button {
						_checkNow()
					} label: {
						Label(.localized("Check Now"), systemImage: "bell.badge.arrowclockwise")
					}
					.disabled(_checking)
				}
			} footer: {
				Text(.localized("Posts a notification when a certificate moves into an expiry window (expired, 3, 7 or 14 days). Each window reminds only once. The check also runs every launch."))
			}
		}
		.navigationBarTitleDisplayMode(.inline)
	}

	private func _setEnabled(_ newValue: Bool) {
		if !newValue {
			_enabled = false
			return
		}

		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
			DispatchQueue.main.async {
				if granted {
					_enabled = true
					Toast.success(.localized("Expiry reminders on"))
				} else {
					_enabled = false
					Toast.error(.localized("Notifications are turned off for VexSign in Settings"))
				}
			}
		}
	}

	private func _checkNow() {
		_checking = true
		Task {
			let pending = await CertificateExpiryMonitor.checkNow()
			await MainActor.run {
				_checking = false
				Toast.info(.localized("%lld expiry reminder(s) pending", arguments: pending), systemImage: "bell.badge")
			}
		}
	}
}
