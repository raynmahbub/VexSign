//
//  AdvancedSigningSettingsView.swift
//  VexSign — Advanced Signing & Binary Patches
//
//  These controls are bound to the same Options object consumed by SigningHandler.
//  They are not a second, settings-only preference store.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct AdvancedSigningSettingsView: View {
	@StateObject private var optionsManager = OptionsManager.shared

	var body: some View {
		NBList(.localized("Advanced Signing & Patches")) {
			headerSection
			sdkSpoofingSection
			compatibilitySection
			machoAndPackagingSection
		}
		.onChange(of: optionsManager.options) { _, _ in
			optionsManager.saveOptions()
		}
	}

	private var headerSection: some View {
		NBSection(.localized("Advanced Signer Engine")) {
			HStack(spacing: 14) {
				ZStack {
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.fill(Color.orange.opacity(0.15))
						.frame(width: 44, height: 44)
					Image(systemName: "cpu.fill")
						.font(.system(size: 20, weight: .bold))
						.foregroundStyle(Color.orange)
				}

				VStack(alignment: .leading, spacing: 3) {
					Text(.localized("Binary & SDK Patching"))
						.font(.headline)
					Text(.localized("Every option below is applied by the active signing pipeline."))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.padding(.vertical, 4)
		}
	}

	private var sdkSpoofingSection: some View {
		NBSection(.localized("Build SDK Spoofing")) {
			Toggle(.localized("Spoof Build SDK Version"), isOn: $optionsManager.options.experiment_supportLiquidGlass)
				.tint(Color.orange)

			if optionsManager.options.experiment_supportLiquidGlass {
				LabeledContent(.localized("Target SDK"), value: "iOS 26.0")
				Text(.localized("The current on-device Mach-O patcher targets the iOS 26 SDK load command."))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		} footer: {
			Text(.localized("Patches the main executable for the iOS 26 SDK and clears UIDesignRequiresCompatibility so modern system UI can render natively."))
		}
	}

	private var compatibilitySection: some View {
		NBSection(.localized("Info.plist Patches")) {
			Toggle(.localized("Force Files App Sharing"), isOn: $optionsManager.options.fileSharing)
				.tint(Color.userTint)

			Toggle(.localized("Remove Minimum iOS Version"), isOn: $optionsManager.options.removeMinimumOSVersion)
				.tint(Color.userTint)

			Toggle(.localized("Strip Existing URL Schemes"), isOn: $optionsManager.options.removeURLScheme)
				.tint(Color.userTint)
		} footer: {
			Text(.localized("These changes are written into the working app bundle before it is signed. Bundle duplication uses the explicit Clone or Duplicate action so this screen never silently changes an app's identity."))
		}
	}

	private var machoAndPackagingSection: some View {
		NBSection(.localized("Mach-O & Binary Optimization")) {
			Toggle(.localized("Mach-O Architecture Thinning"), isOn: $optionsManager.options.thinMachOBinaries)
				.tint(Color.userTint)
		} footer: {
			Text(.localized("Strips non-ARM64 slices from Mach-O binaries before signing. Leave this off when the output must support another architecture."))
		}
	}
}
