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
		VStack(alignment: .leading, spacing: 14) {
			if let error = store.lastError {
				Label(error, systemImage: "exclamationmark.triangle.fill")
					.font(.callout)
					.foregroundStyle(.red)
			}
			if let error = store.credentialStorageError {
				Label(error, systemImage: "key.horizontal.fill")
					.font(.callout)
					.foregroundStyle(.orange)
			}
			if let error = store.certificateTrustError {
				Label(error, systemImage: "checkmark.seal")
					.font(.callout)
					.foregroundStyle(.orange)
			}

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
		VStack(alignment: .leading, spacing: 10) {
			Text("Pending updates")
				.font(.headline)
			_updatesContent
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(16)
		.glassBackgroundEffect()
	}

	@ViewBuilder
	private var _updatesContent: some View {
		if let result = store.updatesResult {
			switch result {
			case .success(let updates):
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
			case .failure(let error):
				_endpointFailure("Updates", error: error)
			}
		} else {
			Text(store.isRefreshing ? "Loading updates…" : "Updates have not been loaded yet.")
				.font(.callout)
				.foregroundStyle(.secondary)
		}
	}

	private var _libraryPanel: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Library")
				.font(.headline)
			_libraryContent
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(16)
		.glassBackgroundEffect()
	}

	@ViewBuilder
	private var _libraryContent: some View {
		if let result = store.libraryResult {
			switch result {
			case .success(let library):
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
			case .failure(let error):
				_endpointFailure("Library", error: error)
			}
		} else {
			Text(store.isRefreshing ? "Loading library…" : "The library has not been loaded yet.")
				.font(.callout)
				.foregroundStyle(.secondary)
		}
	}

	private func _endpointFailure(_ section: String, error: CompanionClientError) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Label(
				error.isAuthenticationFailure ? "Authentication failed" : "\(section) temporarily unavailable",
				systemImage: error.isAuthenticationFailure ? "lock.fill" : "exclamationmark.triangle.fill"
			)
			Text(error.localizedDescription)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.foregroundStyle(error.isAuthenticationFailure ? Color.red : Color.orange)
	}
}

// MARK: - Connection

struct VisionConnectView: View {
	@EnvironmentObject private var store: CompanionStore
	@State private var _showForgetConfirmation = false

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Label("Connect to VexSign", systemImage: "wifi")
				.font(.title3.bold())

			Text("Start the Web Manager on your iPhone (Settings → Web Manager → Allow This Network). Enter its HTTPS address and compare the device CA SHA-256 fingerprint with the value shown on that iPhone before pairing.")
				.font(.callout)
				.foregroundStyle(.secondary)

			TextField("https://192.168.1.20:8080", text: $store.address)
				.textFieldStyle(.roundedBorder)

			if store.requiresCertificatePairing {
				TextField("Device CA SHA-256 fingerprint from iPhone Settings", text: $store.pairingFingerprint)
					.textFieldStyle(.roundedBorder)
					.textInputAutocapitalization(.characters)
					.autocorrectionDisabled()
			}

			if let fingerprint = store.trustedCertificateFingerprint {
				Text("Trusted certificate: \(fingerprint)")
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
			}
			if store.trustedCertificateFingerprint != nil || store.certificateTrustError != nil {
				Button("Forget Trusted Certificate", role: .destructive) {
					_showForgetConfirmation = true
				}
			}
			if let error = store.certificateTrustError {
				Text(error)
					.font(.footnote)
					.foregroundStyle(.orange)
			}

			TextField("Web Manager username (if a password is set)", text: $store.username)
				.textFieldStyle(.roundedBorder)

			SecureField("Web Manager password", text: $store.password)
				.textFieldStyle(.roundedBorder)

			SecureField("API token (alternative to username and password)", text: $store.apiToken)
				.textFieldStyle(.roundedBorder)

			Toggle("Allow unencrypted HTTP on a trusted local network", isOn: $store.allowsInsecureHTTP)
			Text("HTTPS verifies the paired device CA and address before sending credentials. HTTP has no encryption or certificate pairing; if enabled, passwords, tokens and library data can be observed on the network.")
				.font(.footnote)
				.foregroundStyle(.secondary)

			HStack {
				Button(store.connectButtonTitle) {
					Task { await store.refresh() }
				}
				.buttonStyle(.borderedProminent)
				.disabled(store.address.trimmingCharacters(in: .whitespaces).isEmpty)

				if store.isRefreshing {
					ProgressView()
				}
			}

			if let error = store.credentialStorageError {
				Text(error)
					.font(.footnote)
					.foregroundStyle(.orange)
			}

			if let error = store.lastError {
				Text(error)
					.font(.footnote)
					.foregroundStyle(.red)
			}

			Text(store.addressHint)
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.padding(20)
		.alert("Forget the saved certificate trust?", isPresented: $_showForgetConfirmation) {
			Button("Forget Trusted Certificate", role: .destructive) {
				store.forgetTrustedCertificate()
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Only forget it after checking the replacement SHA-256 fingerprint directly in VexSign on your iPhone. The next connection must be paired again.")
		}
	}
}
