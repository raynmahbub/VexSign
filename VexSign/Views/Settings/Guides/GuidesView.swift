//
//  GuidesView.swift
//  VexSign
//
//  Independent iOS/iPadOS step-by-step guides explaining VexSign's
//  signing, installation, and troubleshooting workflows.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct GuidesView: View {
	private let topics = GuideTopic.all

	var body: some View {
		NBList(.localized("Guides")) {
			NBSection(.localized("Get Started")) {
				ForEach(topics) { topic in
					NavigationLink {
						GuideDetailView(topic: topic)
					} label: {
						Label {
							VStack(alignment: .leading, spacing: 3) {
								Text(topic.title)
								Text(topic.subtitle)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						} icon: {
							Image(systemName: topic.icon)
								.foregroundStyle(Color.userTint)
						}
					}
				}
			} footer: {
				Text(.localized("Guides are written for VexSign's iPhone and iPad workflows. Certificate and install outcomes still depend on Apple's current device and profile rules."))
			}
		}
	}
}

private struct GuideTopic: Identifiable {
	let id: String
	let title: String
	let subtitle: String
	let icon: String
	let steps: [String]

	static let all: [GuideTopic] = [
		GuideTopic(
			id: "signing",
			title: .localized("Sign an IPA"),
			subtitle: .localized("Import, choose a certificate, and install safely"),
			icon: "signature",
			steps: [
				.localized("Open Files or Library and import an IPA."),
				.localized("Open the app's signing screen and select a certificate with a valid provisioning profile."),
				.localized("Review the preflight warnings before signing. Keep extensions and entitlements unless you know they are not needed."),
				.localized("Start signing, follow the progress activity, then install from the completion action."),
				.localized("If installation fails, open Settings → Activity Logs and export the diagnostic log before trying again.")
			]
		),
		GuideTopic(
			id: "sources",
			title: .localized("Sources and Updates"),
			subtitle: .localized("Add repositories, choose priority, and update apps"),
			icon: "globe.desk",
			steps: [
				.localized("Open App Store and add an HTTPS AltStore-compatible repository."),
				.localized("Use Repository Priority to decide which source wins when duplicate bundle IDs are published."),
				.localized("Turn on duplicate hiding when you want one canonical app card."),
				.localized("Use Updates to review versions, certificate choice, and automatic update rules before signing.")
			]
		),
		GuideTopic(
			id: "tweaks",
			title: .localized("Tweaks and Dylibs"),
			subtitle: .localized("Import, inspect, and inject compatible components"),
			icon: "wrench.and.screwdriver",
			steps: [
				.localized("Open Settings → Tweaks & Dylibs and import a dylib, deb, framework, or bundle."),
				.localized("Use Dylib Browser in an app's signing options to inspect linked libraries and avoid duplicate injections."),
				.localized("Select a tweak, review its injection path and extension targeting, then sign a copy."),
				.localized("Do not inject a component unless its architecture, dependencies, and certificate entitlements are compatible.")
			]
		),
		GuideTopic(
			id: "jit-location",
			title: .localized("JIT and Location Simulation"),
			subtitle: .localized("Pair the device and confirm simulation state"),
			icon: "bolt.badge.automatic",
			steps: [
				.localized("Open Settings → JIT & On-Device Pairing and follow the pairing instructions."),
				.localized("Run the self-test before attaching JIT to an emulator or other app."),
				.localized("Choose a location from the map in Location Simulator, then use the Live Activity to confirm when simulation is active."),
				.localized("Stop simulation from the location controls before disconnecting or troubleshooting the paired device.")
			]
		),
		GuideTopic(
			id: "troubleshooting",
			title: .localized("Troubleshooting"),
			subtitle: .localized("Find the real reason signing or installation failed"),
			icon: "stethoscope",
			steps: [
				.localized("Check that the certificate password opens the P12 and that the profile has not expired."),
				.localized("Keep the device unlocked and on the same local network when using the local install server."),
				.localized("If a local address is blocked, export Diagnostics and check the Local Network permission in iOS Settings."),
				.localized("Retry after clearing only the affected download or signing job; do not reset certificates unless the diagnostic points to corrupted storage.")
			]
		)
	]
}

private struct GuideDetailView: View {
	let topic: GuideTopic

	var body: some View {
		NBList(topic.title) {
			Section {
				ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
					HStack(alignment: .top, spacing: 12) {
						Text(verbatim: "\(index + 1)")
							.font(.headline.monospacedDigit())
							.foregroundStyle(Color.userTint)
							.frame(width: 24, height: 24)
							.background(Color.userTint.opacity(0.12), in: Circle())
						Text(step)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.padding(.vertical, 5)
				}
			} header: {
				Label(topic.subtitle, systemImage: topic.icon)
			} footer: {
				Text(.localized("This guide is informational. Always review the preflight checks and the certificate/profile capabilities shown by VexSign."))
			}
		}
	}
}
