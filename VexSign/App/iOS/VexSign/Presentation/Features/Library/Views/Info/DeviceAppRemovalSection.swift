//
//  DeviceAppRemovalSection.swift
//  VexSign
//
//  "Remove from Device" on an app's info screen: one destructive action, confirmed by
//  name, with the outcome reported as what the device said afterwards.
//

import SwiftUI
import NimbleExtensions

struct DeviceAppRemovalSection: View {
	let bundleIdentifier: String
	let name: String

	@State private var _isConfirming = false
	@State private var _isRemoving = false
	@State private var _outcome: DeviceAppRemoval.Outcome?

	private var _refusal: DeviceAppRemoval.Refusal? {
		DeviceAppRemoval.refusal(for: bundleIdentifier, ownBundleIdentifier: Bundle.main.bundleIdentifier)
	}

	var body: some View {
		Section {
			Button(role: .destructive) {
				_isConfirming = true
			} label: {
				HStack {
					Label(String.localized("Remove from Device"), systemImage: "trash")
					if _isRemoving {
						Spacer()
						ProgressView()
					}
				}
			}
			.disabled(_isRemoving || _refusal != nil)
			.confirmationDialog(
				String.localized("Remove %@ from this device?", arguments: name),
				isPresented: $_isConfirming,
				titleVisibility: .visible
			) {
				Button(String.localized("Remove App and Its Data"), role: .destructive) { _remove() }
				Button(String.localized("Cancel"), role: .cancel) {}
			} message: {
				Text(String.localized("This deletes the installed app and everything it has stored, and cannot be undone. The copy in your Library is kept. Identifier: %@", arguments: bundleIdentifier))
			}

			if let outcome = _outcome {
				VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
					Text(outcome.title).font(.subheadline.weight(.semibold))
					Text(outcome.message).font(.caption).foregroundStyle(.secondary)
				}
				.accessibilityElement(children: .combine)
			}
		} header: {
			Text(String.localized("Device"))
		} footer: {
			Text(_refusal?.errorDescription
				?? String.localized("Uses the pairing session, so it needs a pairing file and the pairing VPN. VexSign reads the device afterwards and reports what it finds."))
		}
	}

	private func _remove() {
		guard !_isRemoving else { return }
		_isRemoving = true
		_outcome = nil
		Task { @MainActor in
			let outcome = await DeviceAppRemoval.remove(bundleIdentifier: bundleIdentifier)
			_outcome = outcome
			_isRemoving = false
		}
	}
}
