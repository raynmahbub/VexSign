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

	private enum Field: Hashable {
		case address
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

			Text("Open VexSign on your iPhone, go to Settings → Web Manager, turn on Allow This Network, then start the server and enter the address it shows, plus the password or API token. The password and token are stored in the Keychain on this device.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 640)

			VStack(alignment: .leading, spacing: 12) {
				TextField("https://192.168.1.20:8080", text: $store.address)
					.focused($_focused, equals: .address)
					.keyboardType(.URL)
					.disableAutocorrection(true)

				TextField("Web Manager username (if a password is set)", text: $store.username)
					.focused($_focused, equals: .username)
					.disableAutocorrection(true)

				TextField("Web Manager password", text: $store.password)
					.focused($_focused, equals: .password)
					.disableAutocorrection(true)

				TextField("API token (alternative to username and password)", text: $store.apiToken)
					.focused($_focused, equals: .token)
					.disableAutocorrection(true)

				// Plaintext HTTP is a deliberate, local-network-only choice: the password
				// and token travel in headers, so the switch is off until it is needed.
				Toggle(isOn: $store.allowInsecureHTTP) {
					Text("Allow HTTP on this network")
				}

				if store.allowInsecureHTTP {
					Text("Only for an iPhone on the same local network. The password and token are sent unencrypted; anyone who can watch this network can read them.")
						.font(.caption2)
						.foregroundStyle(.orange)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.frame(maxWidth: 520)

			Button {
				Task { await store.refresh() }
			} label: {
				Text("Connect")
					.frame(maxWidth: 260)
			}
			.buttonStyle(.borderedProminent)
			.disabled(store.address.trimmingCharacters(in: .whitespaces).isEmpty)

			if let error = store.lastError {
				Text(error)
					.font(.footnote)
					.foregroundStyle(.red)
					.multilineTextAlignment(.center)
					.frame(maxWidth: 640)
			}

			if let issue = store.credentialIssue {
				Text(issue)
					.font(.footnote)
					.foregroundStyle(.orange)
					.multilineTextAlignment(.center)
					.frame(maxWidth: 640)
			}

			if store.hasUnmigratedCredential {
				Text("A password or token saved by an earlier version is still stored insecurely. Re-enter it above; the Keychain copy replaces it.")
					.font(.caption2)
					.foregroundStyle(.orange)
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
	}
}
