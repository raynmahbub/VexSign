//
//  VisionHomeView.swift
//  VexSignVision
//
//  The spatial layout: a hero certificate panel beside the counts, with updates
//  and the library in a scrollable column. Glass surfaces and hover effects are
//  the visionOS idiom; nothing here is iOS-only.
//

import SwiftUI

struct VisionHomeView: View {
	@EnvironmentObject private var store: CompanionStore

	var body: some View {
		if store.isConfigured {
			_content
		} else {
			VisionConnectView()
		}
	}

	private var _content: some View {
		HStack(alignment: .top, spacing: 20) {
			VStack(spacing: 16) {
				_certificatePanel
				_countsPanel
			}
			.frame(width: 340)

			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					_updatesPanel
					_libraryPanel
				}
				.padding(.vertical, 4)
			}
			.frame(maxWidth: .infinity)
		}
		.padding(20)
	}

	// MARK: Panels

	private var _certificatePanel: some View {
		let status = store.snapshot?.status

		return VStack(alignment: .leading, spacing: 6) {
			Label(status?.certName ?? "Certificate", systemImage: (status?.certRevoked ?? false) ? "xmark.seal.fill" : "checkmark.seal.fill")
				.font(.callout.weight(.semibold))
				.foregroundStyle(_certTint)
				.lineLimit(1)

			Text(status?.certLabel ?? "—")
				.font(.system(size: 56, weight: .bold, design: .rounded))
				.foregroundStyle(_certTint)
				.contentTransition(.numericText())

			Text(status?.certSummary ?? "Waiting for the iPhone…")
				.font(.callout)
				.foregroundStyle(.secondary)

			if let updated = store.lastUpdated {
				Text("Updated \(updated, style: .relative) ago")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(18)
		.glassBackgroundEffect()
	}

	private var _certTint: Color {
		guard let status = store.snapshot?.status else { return .secondary }
		if status.certRevoked { return .red }
		guard let days = status.certDaysRemaining else { return .secondary }
		if days < 7 { return .red }
		if days < 30 { return .orange }
		return .green
	}

	private var _countsPanel: some View {
		let status = store.snapshot?.status

		return VStack(spacing: 12) {
			_row("Apps", value: status.map { "\($0.installedApps)" } ?? "—")
			Divider()
			_row("Signed", value: status.map { "\($0.signedApps)" } ?? "—")
			Divider()
			_row("Updates", value: status.map { "\($0.pendingUpdates)" } ?? "—")
			Divider()
			_row(
				"Free space",
				value: status?.storageFree.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
			)
		}
		.padding(18)
		.glassBackgroundEffect()
	}

	private func _row(_ title: String, value: String) -> some View {
		HStack {
			Text(title)
				.font(.callout)
				.foregroundStyle(.secondary)
			Spacer()
			Text(value)
				.font(.title3.bold())
				.contentTransition(.numericText())
		}
	}

	private var _updatesPanel: some View {
		let updates = store.snapshot?.updates ?? []

		return VStack(alignment: .leading, spacing: 10) {
			Text("Pending updates")
				.font(.headline)

			if updates.isEmpty {
				Text("Everything is up to date.")
					.font(.callout)
					.foregroundStyle(.secondary)
			} else {
				ForEach(updates.prefix(20)) { update in
					HStack {
						VStack(alignment: .leading, spacing: 1) {
							Text(update.name)
								.font(.callout.weight(.medium))
							Text(update.bundleID)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
						Text("\(update.installedVersion ?? "?") → \(update.availableVersion ?? "?")")
							.font(.callout.monospacedDigit())
							.foregroundStyle(.orange)
					}
					.padding(.vertical, 6)
					.padding(.horizontal, 10)
					.hoverEffect()
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(16)
		.glassBackgroundEffect()
	}

	private var _libraryPanel: some View {
		let library = store.snapshot?.library ?? []

		return VStack(alignment: .leading, spacing: 10) {
			Text("Library")
				.font(.headline)

			if library.isEmpty {
				Text("Nothing in the library yet.")
					.font(.callout)
					.foregroundStyle(.secondary)
			} else {
				ForEach(library.prefix(40)) { app in
					HStack(spacing: 10) {
						Image(systemName: app.signed ? "checkmark.seal.fill" : "app.dashed")
							.foregroundStyle(app.signed ? .green : .secondary)
						Text(app.name)
							.font(.callout)
							.lineLimit(1)
						Spacer()
						Text(app.version)
							.font(.caption.monospacedDigit())
							.foregroundStyle(.secondary)
					}
					.padding(.vertical, 4)
					.hoverEffect()
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(16)
		.glassBackgroundEffect()
	}
}

// MARK: - Connection

struct VisionConnectView: View {
	@EnvironmentObject private var store: CompanionStore

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Label("Connect to VexSign", systemImage: "wifi")
				.font(.title3.bold())

			Text("Start the Web Manager on your iPhone (Settings → Web Manager → Allow This Network) and enter the address it prints, plus its password or API token. Both are stored in the Keychain on this device.")
				.font(.callout)
				.foregroundStyle(.secondary)

			TextField("https://192.168.1.20:8080", text: $store.address)
				.textFieldStyle(.roundedBorder)

			TextField("Web Manager username (if a password is set)", text: $store.username)
				.textFieldStyle(.roundedBorder)

			TextField("Web Manager password", text: $store.password)
				.textFieldStyle(.roundedBorder)

			TextField("API token (alternative to username and password)", text: $store.apiToken)
				.textFieldStyle(.roundedBorder)

			// Plaintext HTTP is opt-in and local-network-only: credentials travel in headers.
			Toggle("Allow HTTP on this network", isOn: $store.allowInsecureHTTP)

			if store.allowInsecureHTTP {
				Text("Only for an iPhone on the same network. The password and token are sent unencrypted.")
					.font(.caption2)
					.foregroundStyle(.orange)
			}

			HStack {
				Button("Connect") {
					Task { await store.refresh() }
				}
				.buttonStyle(.borderedProminent)
				.disabled(store.address.trimmingCharacters(in: .whitespaces).isEmpty)

				if store.isRefreshing {
					ProgressView()
				}
			}

			if let error = store.lastError {
				Text(error)
					.font(.footnote)
					.foregroundStyle(.red)
			}

			if let issue = store.credentialIssue {
				Text(issue)
					.font(.footnote)
					.foregroundStyle(.orange)
			}

			if store.hasUnmigratedCredential {
				Text("A password or token saved by an earlier version is still stored insecurely. Re-enter it above.")
					.font(.caption2)
					.foregroundStyle(.orange)
			}

			Text(store.addressHint)
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.padding(20)
	}
}
