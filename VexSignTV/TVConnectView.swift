//
//  TVConnectView.swift
//  VexSignTV
//
//  One-time pairing: type the address the iPhone's Web Manager prints. Nothing is
//  discovered automatically — Bonjour would need a service the Web Manager does
//  not advertise, and guessing an address is worse than asking for one.
//

import SwiftUI

struct TVConnectView: View {
	@EnvironmentObject private var store: CompanionStore
	@FocusState private var _focused: Field?
	@State private var _showForgetConfirmation = false

	private enum Field: Hashable {
		case address
		case fingerprint
		case username
		case password
		case token
	}

	var body: some View {
		VStack(spacing: 24) {
			Image(systemName: "appletv.fill")
				.font(.system(size: 64))
				.foregroundStyle(.secondary)

			Text("Connect to VexSign")
				.font(.title.bold())

			Text("Open VexSign on your iPhone → Settings → Web Manager, turn on Allow This Network and start the server. Enter its HTTPS address and compare the device CA SHA-256 fingerprint with the value shown on that iPhone before pairing.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 640)

			VStack(alignment: .leading, spacing: 12) {
				TextField("https://192.168.1.20:8080", text: $store.address)
					.focused($_focused, equals: .address)
					.keyboardType(.URL)
					.disableAutocorrection(true)

				if store.requiresCertificatePairing {
					TextField("Device CA SHA-256 fingerprint from iPhone Settings", text: $store.pairingFingerprint)
						.focused($_focused, equals: .fingerprint)
						.disableAutocorrection(true)
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
					.focused($_focused, equals: .username)
					.disableAutocorrection(true)

				SecureField("Web Manager password", text: $store.password)
					.focused($_focused, equals: .password)
					.disableAutocorrection(true)

				SecureField("API token (alternative to username and password)", text: $store.apiToken)
					.focused($_focused, equals: .token)
					.disableAutocorrection(true)

				Toggle("Allow unencrypted HTTP on a trusted local network", isOn: $store.allowsInsecureHTTP)
				Text("HTTPS verifies the paired device CA and address before sending credentials. HTTP has no encryption or certificate pairing; if enabled, passwords, tokens and library data can be observed on the network.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: 520)

			Button {
				Task { await store.refresh() }
			} label: {
				Text(store.connectButtonTitle)
					.frame(maxWidth: 260)
			}
			.buttonStyle(.borderedProminent)
			.disabled(store.address.trimmingCharacters(in: .whitespaces).isEmpty)

			if let error = store.credentialStorageError {
				Text(error)
					.font(.footnote)
					.foregroundStyle(.orange)
					.multilineTextAlignment(.center)
					.frame(maxWidth: 640)
			}

			if let error = store.lastError {
				Text(error)
					.font(.footnote)
					.foregroundStyle(.red)
					.multilineTextAlignment(.center)
					.frame(maxWidth: 640)
			}

			Text(store.addressHint)
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.padding(48)
		.onAppear {
			_focused = .address
		}
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
