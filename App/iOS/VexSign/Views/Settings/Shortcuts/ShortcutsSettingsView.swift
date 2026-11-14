//
//  ShortcutsSettingsView.swift
//  VexSign
//
//  Settings → Siri & Shortcuts. App Shortcuts register themselves with the
//  system, so there is nothing to switch on here — this screen exists so the
//  whole catalogue is discoverable in one place: what each action does, which
//  ones answer to Siri, and where to build an automation.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct ShortcutsSettingsView: View {
	var body: some View {
		NBList(.localized("Siri & Shortcuts")) {
			_introSection
			_actionsSection
			_automationSection
		}
	}

	// MARK: Sections

	@ViewBuilder
	private var _introSection: some View {
		Section {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text(.localized("These actions are already in the Shortcuts app"))
					Text(.localized("They run on-device, with your own certificate and options. Nothing is sent anywhere."))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} icon: {
				Image(systemName: "checkmark.circle.fill")
					.foregroundStyle(.green)
			}

			Button {
				UIApplication.open("shortcuts://")
			} label: {
				Label(.localized("Open Shortcuts"), systemImage: "arrow.up.forward.app")
			}
		} footer: {
			Text(.localized("Siri phrases need iOS 17 or later. Everything else works from iOS 16."))
		}
	}

	@ViewBuilder
	private var _actionsSection: some View {
		NBSection(.localized("Actions")) {
			if #available(iOS 17.0, *) {
				ForEach(VexSignShortcutCatalogue.entries) { entry in
					_row(entry)
				}
			} else {
				Text(.localized("The App Shortcuts catalogue needs iOS 17 or later."))
					.foregroundStyle(.secondary)
			}
		}
	}

	@ViewBuilder
	private var _automationSection: some View {
		Section {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text(.localized("Automations"))
					Text(.localized("“Get Pending Update Count” returns a number, so a Personal Automation can branch on it — for example: when I connect to Wi-Fi, refresh repositories, and if updates exist, update all apps."))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} icon: {
				Image(systemName: "gearshape.2")
					.foregroundStyle(Color.accentColor)
			}
		} footer: {
			Text(.localized("Signing from the background still needs VexSign's own automation allowance: Settings → Automation decides whether an update pass signs and queues, or only reports."))
		}
	}

	// MARK: Row

	@available(iOS 17.0, *)
	@ViewBuilder
	private func _row(_ entry: VexSignShortcutCatalogue.Entry) -> some View {
		Button {
			_copy(entry)
		} label: {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text(entry.title)
					Text(entry.detail)
						.font(.caption)
						.foregroundStyle(.secondary)
					if let phrase = entry.phrase {
						Text(String.localized("Say “%@”", arguments: phrase))
							.font(.caption2)
							.foregroundStyle(Color.accentColor)
					} else {
						Text(.localized("No Siri phrase — available in the Shortcuts app"))
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
				}
			} icon: {
				Image(systemName: entry.systemImage)
					.foregroundStyle(Color.accentColor)
			}
		}
		.buttonStyle(.plain)
	}

	/// Copying the phrase is the useful action here: it is what you type into the
	/// Shortcuts editor when you build an automation by hand.
	@available(iOS 17.0, *)
	private func _copy(_ entry: VexSignShortcutCatalogue.Entry) {
		UIPasteboard.general.string = entry.phrase ?? entry.title
	}
}
