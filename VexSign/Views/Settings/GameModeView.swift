//
//  GameModeView.swift
//  VexSign
//
//  Settings → Game Mode: the switch itself lives on the Settings screen so it is one tap away
//  when a game starts. This screen explains exactly what stops, and lets paused downloads go
//  again once the mode is off.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct GameModeView: View {
	@AppStorage(GameMode.enabledKey) private var _isEnabled: Bool = false
	@ObservedObject private var _downloads = DownloadManager.shared

	// MARK: Body
	var body: some View {
		NBList(.localized("Game Mode")) {
			_toggleSection
			_effectsSection
			_downloadsSection
			_signingSection
		}
	}

	// MARK: Sections

	@ViewBuilder
	private var _toggleSection: some View {
		Section {
			Toggle(isOn: $_isEnabled) {
				Label(.localized("Game Mode"), systemImage: "gamecontroller")
			}
			.nbOnChange(of: _isEnabled) { enabled in
				enabled ? GameMode.enable() : GameMode.disable()
			}
		} footer: {
			Text(.localized("Leave this on while you play: VexSign stops downloading and stops its background update pass, so it uses no data and next to no battery."))
		}
	}

	@ViewBuilder
	private var _effectsSection: some View {
		NBSection(.localized("What It Pauses")) {
			ForEach(GameMode.effects) { effect in
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text(effect.title)
						Text(effect.detail)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				} icon: {
					Image(systemName: effect.systemImage)
						.foregroundStyle(Color.accentColor)
				}
				.padding(.vertical, 2)
			}
		}
	}

	@ViewBuilder
	private var _downloadsSection: some View {
		let paused = _pausedDownloads

		if !paused.isEmpty || _isEnabled {
			Section {
				LabeledContent(.localized("Paused downloads"), value: paused.count.description)

				Button {
					_downloads.resumeAllDownloads()
				} label: {
					Label(.localized("Resume Downloads"), systemImage: "play.circle")
				}
				.disabled(_isEnabled || paused.isEmpty)
			} header: {
				Text(.localized("Downloads"))
			} footer: {
				Text(
					_isEnabled
						? .localized("Downloads stay paused until Game Mode is off.")
						: .localized("These were paused when Game Mode was switched on. They resume when you tap the button above.")
				)
			}
		}
	}

	@ViewBuilder
	private var _signingSection: some View {
		Section {
			NavigationLink(destination: ConfigurationView()) {
				Label(.localized("Signing Options"), systemImage: "signature")
			}
		} header: {
			Text(.localized("Game Mode for Signed Apps"))
		} footer: {
			Text(.localized("Separate from this switch: Signing Options → Game Mode writes GCSupportsGameMode into an app you sign, so iOS gives that app the system's own Game Mode."))
		}
	}

	// MARK: Derived

	private var _pausedDownloads: [Download] {
		_downloads.downloads.filter { $0.isPaused && $0.progress > 0 && $0.progress < 1.0 }
	}
}
