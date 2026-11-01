//
//  CompanionSettingsView.swift
//  VexSign
//
//  Settings → Companion Devices. Two different bridges live here, and they are
//  kept apart on purpose:
//
//    • Apple Watch  — WatchConnectivity. The phone pushes a snapshot and runs the
//      four commands the watch sends back. Nothing leaves the pair.
//    • Apple TV / Vision Pro — the Web Manager the app already runs. Those apps
//      read `/api/status`, `/api/library` and `/api/updates`, so "pairing" is
//      nothing more than typing the printed address into the companion.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct CompanionSettingsView: View {
	@ObservedObject private var _bridge = CompanionBridge.shared
	@ObservedObject private var _webManager = WebManager.shared
	@State private var _copied: String?

	var body: some View {
		NBList(.localized("Companion Devices")) {
			_watchSection
			_bridgeSection
			_companionAppsSection
		}
	}

	// MARK: Watch

	@ViewBuilder
	private var _watchSection: some View {
		Section {
			Toggle(isOn: Binding(
				get: { CompanionBridge.isEnabled },
				set: { _bridge.setEnabled($0) }
			)) {
				Label(.localized("Apple Watch companion"), systemImage: "applewatch")
			}

			if CompanionBridge.isEnabled {
				_statusRow(.localized("Watch paired"), value: _bridge.isWatchPaired)
				_statusRow(.localized("VexSign installed on watch"), value: _bridge.isWatchAppInstalled)
				_statusRow(.localized("Reachable now"), value: _bridge.isReachable)

				if let push = _bridge.lastPush {
					Text(String.localized("Last snapshot sent %@", arguments: push.formatted(date: .omitted, time: .standard)))
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				Button {
					_bridge.pushSnapshot()
				} label: {
					Label(.localized("Send Snapshot Now"), systemImage: "arrow.up.doc")
				}
				.disabled(!_bridge.isWatchPaired)
			}
		} footer: {
			Text(.localized("The watch shows your certificate countdown, library and pending updates, and can trigger a refresh, a certificate check, Update All or a cleanup on this phone. It cannot sign or install anything itself."))
		}
	}

	@ViewBuilder
	private func _statusRow(_ title: String, value: Bool) -> some View {
		HStack {
			Text(title)
			Spacer()
			Text(value ? .localized("Yes") : .localized("No"))
				.foregroundStyle(value ? Color.green : Color.secondary)
		}
	}

	// MARK: Bridge state

	@ViewBuilder
	private var _bridgeSection: some View {
		if let command = _bridge.lastCommand {
			Section {
				Text(String.localized("Last command from a companion: %@", arguments: command))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	// MARK: TV / Vision Pro

	@ViewBuilder
	private var _companionAppsSection: some View {
		NBSection(.localized("Apple TV & Vision Pro")) {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text(_webManager.isRunning ? WebManager.shared.httpURL : .localized("Web Manager is off"))
					Text(.localized("Enter this address in the companion app. It reads the same status, library and update endpoints the automation API uses."))
						.font(.caption)
						.foregroundStyle(.secondary)
					if _webManager.isRunning && _webManager.effectiveBindMode == .thisDevice {
						Text(.localized("The server currently accepts connections from this device only. Turn on “Allow This Network” in Web Manager so the Apple TV can reach it."))
							.font(.caption)
							.foregroundStyle(.orange)
					}
				}
			} icon: {
				Image(systemName: "externaldrive.badge.wifi")
					.foregroundStyle(_webManager.isRunning ? Color.accentColor : Color.secondary)
			}

			Button {
				_copy(_webManager.httpURL)
			} label: {
				Label(.localized("Copy Address"), systemImage: "doc.on.doc")
			}
			.disabled(!_webManager.isRunning)

			NavigationLink(destination: WebManagerView()) {
				Label(.localized("Web Manager & File Server"), systemImage: "gearshape")
			}
		}
	}

	private func _copy(_ text: String) {
		UIPasteboard.general.string = text
		_copied = text
	}
}
