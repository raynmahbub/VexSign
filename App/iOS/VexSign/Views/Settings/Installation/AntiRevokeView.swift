//
//  AntiRevokeView.swift
//  VexSign
//
//  Settings → Installation → Anti-Revoke: builds a per-device DNS profile that pins a
//  DNS-over-HTTPS resolver for Apple's revocation-check hosts. The user supplies the endpoint
//  (a sinkhole DoH they trust) because VexSign ships no hosted service of its own.
//  Also supports NovaDNS Dynamic for automated PPQ bypass during installation.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct AntiRevokeView: View {
	@AppStorage("VexSign.useNovaDNSDynamic") private var _useNovaDNSDynamic: Bool = false
	@State private var _endpoint = ""
	@State private var _isBuilding = false
	@State private var _isSyncingRules = false
	@State private var _lastBuiltURL: URL?
	@State private var _currentRules: DynamicDNSRules = NovaDNSDynamic.loadCachedRules()
	/// The rule-list override as typed. Empty means "use the built-in default".
	@State private var _rulesEndpointInput = ""

	private var _hasProfile: Bool { AntiRevokeManager.shared.profileURL != nil }

	// MARK: Body
	var body: some View {
		NBList(.localized("Anti-Revoke")) {
			_statusSection
			_novaDNSSection
			_configSection
			_hostsSection
		}
		.task {
			_currentRules = NovaDNSDynamic.loadCachedRules()
			_rulesEndpointInput = NovaDNSDynamic.customRulesURL ?? ""
			if _endpoint.isEmpty {
				_endpoint = _currentRules.primaryEndpoint
			}
		}
		.onChange(of: _useNovaDNSDynamic) { _, enabled in
			// switching this on changes how the device resolves Apple's checks, so it is logged.
			if enabled {
				FileLogger.log("NovaDNS Dynamic enabled — endpoint \(NovaDNSDynamic.effectiveRulesURLString)", category: "antirevoke")
			} else {
				FileLogger.log("NovaDNS Dynamic disabled", category: "antirevoke")
			}
		}
	}

	@ViewBuilder
	private var _statusSection: some View {
		Section {
			LabeledContent(.localized("Status")) {
				Text(verbatim: _hasProfile ? String.localized("Ready to install") : String.localized("Not protected"))
					.foregroundStyle(_hasProfile ? Color.green : Color.secondary)
			}
		} footer: {
			Text(.localized("iOS only installs DNS profiles from Settings, so the profile is shared for you to save and open there. It cannot un-revoke a certificate Apple has already revoked — it slows down future checks and keep a still-valid certificate working longer."))
		}
	}

	@ViewBuilder
	private var _novaDNSSection: some View {
		Section {
			HStack {
				Toggle(isOn: $_useNovaDNSDynamic) {
					Text(.localized("Use NovaDNS Dynamic"))
				}
				Button {
					guard let url = URL(string: "https://sideloading.net/dns/") else { return }
					Task { @MainActor in
						UIApplication.shared.open(url)
					}
				} label: {
					Image(systemName: "questionmark.circle.fill")
						.foregroundColor(.accentColor)
				}
				.buttonStyle(.plain)
			}

			// the endpoint is visible and replaceable. It used to be hard-coded to a
			// third-party host with no way to see or change it.
			LabeledContent(.localized("Endpoint")) {
				Text(verbatim: NovaDNSDynamic.effectiveRulesURLString)
					.font(.caption)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.trailing)
			}

			TextField(.localized("Rule list URL (https)"), text: $_rulesEndpointInput)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.keyboardType(.URL)
				.onSubmit { _saveRulesEndpoint() }

			HStack {
				Button {
					_saveRulesEndpoint()
				} label: {
					Text(.localized("Use This Endpoint"))
				}

				Spacer()

				Button {
					_rulesEndpointInput = ""
					NovaDNSDynamic.setCustomRulesURL(nil)
					Toast.success(.localized("Endpoint reset"), systemImage: "arrow.uturn.backward")
				} label: {
					Text(.localized("Reset"))
						.foregroundColor(.secondary)
				}
			}
			.font(.callout)

			Button {
				_syncRemoteRules()
			} label: {
				HStack {
					if _isSyncingRules {
						ProgressView()
							.padding(.trailing, 2)
						Text(.localized("Updating Rules…"))
					} else {
						Label(.localized("Sync Dynamic Rules"), systemImage: "arrow.triangle.2.circlepath")
					}
					Spacer()
					if let updated = _currentRules.lastUpdated {
						Text(updated)
							.font(.caption)
							.foregroundColor(.secondary)
					}
				}
			}
			.disabled(_isSyncingRules)
		} header: {
			Text(.localized("Dynamic Anti-Revoke"))
		} footer: {
			Text(.localized("Off by default. When it is on, VexSign asks the endpoint above to let Apple's install-time checks through for the duration of an install. That is a third-party server acting on your device's behalf — VexSign cannot guarantee what it does with your queries, and none of this can restore or protect a certificate Apple has already revoked."))
		}
	}

	@ViewBuilder
	private var _configSection: some View {
		Section {
			TextField(.localized("DNS-over-HTTPS endpoint"), text: $_endpoint)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.keyboardType(.URL)

			Button {
				_build()
			} label: {
				if _isBuilding {
					HStack {
						ProgressView()
							.padding(.trailing, 2)
						Text(.localized("Building…"))
					}
				} else {
					Label(.localized("Generate Profile"), systemImage: "shield.lefthalf.filled")
				}
			}
			.disabled(_isBuilding)

			if let url = _lastBuiltURL ?? AntiRevokeManager.shared.profileURL {
				Button {
					AntiRevokeManager.shareProfile(url)
				} label: {
					Label(.localized("Share Profile"), systemImage: "square.and.arrow.up")
				}

				Button(role: .destructive) {
					AntiRevokeManager.shared.removeGeneratedProfile()
					_lastBuiltURL = nil
					Toast.success(.localized("Profile removed"), systemImage: "trash")
				} label: {
					Label(.localized("Delete Profile"), systemImage: "trash")
				}
			}
		} header: {
			Text(.localized("Resolver"))
		} footer: {
			Text(.localized("Point this at a DNS-over-HTTPS server that refuses to answer Apple's revocation hosts. Without a blocking resolver the profile does nothing — VexSign runs no server of its own."))
		}
	}

	@ViewBuilder
	private var _hostsSection: some View {
		Section {
			ForEach(AntiRevokeManager.revocationHosts, id: \.self) { host in
				Text(host)
					.font(.system(.subheadline, design: .monospaced))
			}
		} header: {
			Text(.localized("Hosts to block"))
		} footer: {
			Text(.localized("Apple queries these hosts to check a certificate's status. A working anti-revoke resolver answers them with nothing, so the check cannot return \"revoked\"."))
		}
	}

	// MARK: Actions

	private func _saveRulesEndpoint() {
		if NovaDNSDynamic.setCustomRulesURL(_rulesEndpointInput) {
			Toast.success(.localized("Endpoint saved"), systemImage: "checkmark.seal")
		} else {
			Toast.error(.localized("Enter an https:// URL for the rule list."), duration: .sticky)
		}
	}

	private func _syncRemoteRules() {
		_isSyncingRules = true
		Task {
			let updated = await NovaDNSDynamic.fetchRules()
			_currentRules = updated
			if _endpoint.isEmpty {
				_endpoint = updated.primaryEndpoint
			}
			_isSyncingRules = false
			Toast.success(.localized("Dynamic rules synced"), systemImage: "checkmark.seal")
		}
	}

	private func _build() {
		let raw = _endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
		let endpoint = raw.isEmpty ? "" : raw

		guard let url = URL(string: endpoint), url.scheme?.lowercased() == "https" else {
			Toast.error(.localized("Enter an https:// DNS-over-HTTPS endpoint."), duration: .sticky)
			return
		}

		_isBuilding = true
		Task {
			let result: Result<URL, Error> = await MainActor.run {
				do {
					let built = try AntiRevokeManager.shared.buildProfile(
						serverName: url.host ?? "Anti-Revoke",
						serverURL: endpoint
					)
					return .success(built)
				} catch {
					return .failure(error)
				}
			}

			_isBuilding = false
			switch result {
			case .success(let built):
				_lastBuiltURL = built
				Toast.success(.localized("Profile ready"), systemImage: "checkmark.seal")
			case .failure(let error):
				Toast.error(error.localizedDescription, duration: .sticky)
			}
		}
	}
}
