//
//  CloudSigningView.swift
//  VexSign
//
//  Settings and configuration view for the Cloud Signing microservice bridge.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct CloudSigningView: View {
	@StateObject private var _client = CloudSigningClient.shared

	var body: some View {
		Form {
			_capabilityNoticeSection
			_enableSection
			_endpointSection
			_connectionSection
			_architectureSection
		}
		.navigationTitle(.localized("Cloud Signing"))
		.navigationBarTitleDisplayMode(.inline)
	}

	// MARK: - Sections

	private var _capabilityNoticeSection: some View {
		NBSection(.localized("Current Build Policy")) {
			HStack(alignment: .top, spacing: 10) {
				Image(systemName: "lock.shield.fill")
					.foregroundStyle(.orange)
					.font(.title3)
				VStack(alignment: .leading, spacing: 3) {
					Text(.localized("Private Key Upload Disabled"))
						.font(.subheadline.weight(.semibold))
					Text(.localized("Remote signing refuses to upload .p12 private keys or passwords on this build. Signing runs locally on this device; this screen lets you configure and health-check a self-hosted cluster endpoint."))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.padding(.vertical, 2)
		}
	}

	private var _enableSection: some View {
		NBSection(.localized("Configuration")) {
			Toggle(.localized("Save Cluster Configuration"), isOn: $_client.isEnabled)
		} footer: {
			Text(.localized("Stores your cluster endpoint preference locally. Active signing remains on-device until a dedicated private-key transfer consent flow is enabled."))
		}
	}

	private var _endpointSection: some View {
		NBSection(.localized("Cluster Endpoint")) {
			HStack {
				Text(.localized("Endpoint"))
					.foregroundStyle(.secondary)
					.frame(width: 80, alignment: .leading)
				TextField("https://cloud.vexsign.app", text: $_client.serverURLString)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.keyboardType(.URL)
			}

			HStack {
				Text(.localized("API Key"))
					.foregroundStyle(.secondary)
					.frame(width: 80, alignment: .leading)
				SecureField(.localized("Optional Bearer Token"), text: $_client.apiKey)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
			}
		} footer: {
			Text(.localized("The base URL of your Fastify cloud-signing instance. The optional bearer token is stored in the iOS Keychain, not in backups."))
		}
	}

	private var _connectionSection: some View {
		Section {
			Button {
				Task { await _client.testConnection() }
			} label: {
				HStack {
					Text(.localized("Test Cluster Health"))
					Spacer()
					if _client.isTesting {
						ProgressView()
					}
				}
			}
			.disabled(_client.isTesting)

			if let result = _client.lastTestResult {
				_resultRow(result, succeeded: _client.lastHealthCheckSucceeded ?? false)
			}
		} footer: {
			Text(.localized("Sends a GET request to /health/live on the configured cluster endpoint without uploading certificates or apps."))
		}
	}

	private func _resultRow(_ result: String, succeeded: Bool) -> some View {
		let symbol = succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
		let tint: Color = succeeded ? .green : .orange

		return HStack(alignment: .top, spacing: 8) {
			Image(systemName: symbol)
				.foregroundStyle(tint)
			Text(result)
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}

	private var _architectureSection: some View {
		NBSection(.localized("Cluster Capabilities (Server Side)")) {
			VStack(alignment: .leading, spacing: 6) {
				Text(.localized("Implemented in companion cloud-signing service:"))
					.font(.footnote.bold())
				_featureRow(String.localized("Live health probe (/health/live) & artifact staging API"))
				_featureRow(String.localized("Isolated zsign/ldid worker queue (blocked for .p12 in this client)"))
				_featureRow(String.localized("Capability-scoped OTA manifest URLs with webhook allowlisting"))
			}
			.padding(.vertical, 4)
		}
	}

	private func _featureRow(_ text: String) -> some View {
		Text(verbatim: "• \(text)")
			.font(.caption)
			.foregroundStyle(.secondary)
	}
}
