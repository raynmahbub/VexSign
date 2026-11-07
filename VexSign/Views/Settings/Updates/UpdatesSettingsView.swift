//
//  UpdatesSettingsView.swift
//  VexSign
//
//  Created by VexSign Team on 05.07.2026.
//

import SwiftUI
import NimbleViews
import UIKit
import NimbleExtensions

struct UpdatesSettingsView: View {
	@ObservedObject private var _manager = SelfUpdateManager.shared
	@AppStorage("VexSign.selfUpdateAutoCheck") private var _autoCheck: Bool = true
	@AppStorage("VexSign.selfUpdateCertIndex") private var _certIndex: Int = -1
	@AppStorage("VexSign.selfUpdateMethod") private var _method: Int = 0
	@AppStorage(AppStoreUpdateTracker.enabledKey) private var _appStoreTracking: Bool = false

	@State private var _selected: SelfUpdateRelease?
	@State private var _serverAddressDraft: String = ""
	@State private var _serverAddressError: String?
	@ObservedObject private var _appStoreTracker = AppStoreUpdateTracker.shared

	private let _certificates = Storage.shared.getAllCertificates()

	var body: some View {
		NBList(.localized("Updates")) {
			_statusSection
			_optionsSection
			_appStoreSection
			if !_manager.ignoredVersions.isEmpty { _ignoredSection }
			Section {
				NavigationLink(destination: UpdateMatchingSettingsView()) {
					Label(.localized("Update Matching"), systemImage: "slider.horizontal.3")
				}
				NavigationLink(destination: FavoritesAndAutoUpdatesSettingsView()) {
					Label(.localized("Favorites & Auto Updates"), systemImage: "star.circle.fill")
				}
				NavigationLink(destination: AllVersionsView()) {
					Label(.localized("All Versions"), systemImage: "square.stack.3d.up")
				}
			}
		}
		.sheet(item: $_selected) { release in
			SelfUpdateSheet(release: release, offersReminders: false)
		}
		.onAppear {
			_serverAddressDraft = _manager.configuredServerAddress
			_manager.refreshConfiguration()
		}
		.onChange(of: _method) { _ in _manager.refreshConfiguration() }
		.task {
			await _manager.check()
		}
	}

	// MARK: App Store tracking

	/// Optional second update source: the public App Store version of each bundle
	/// ID, so apps whose sideloaded copy is behind the store release get a badge.
	private var _appStoreSection: some View {
		NBSection(.localized("App Store Tracking")) {
			Toggle(.localized("Check the App Store"), isOn: $_appStoreTracking)

			Button {
				AppStoreUpdateTracker.shared.clearCache()
				Toast.info(.localized("Cleared the App Store version cache."))
			} label: {
				Label(.localized("Clear Cache"), systemImage: "trash")
			}
			.disabled(_appStoreTracker.infos.isEmpty)
		} footer: {
			Text(.localized("Looks each bundle identifier up on the public iTunes Search API and badges the library when a newer version exists. Nothing is uploaded beyond the bundle identifier."))
		}
	}

	// MARK: Status

	private var _statusSection: some View {
		NBSection(.localized("Current Version")) {
			HStack {
				Text(.localized("Installed"))
				Spacer()
				Text(Bundle.main.version).foregroundStyle(.secondary)
			}
			if let available = _manager.available {
				HStack {
					Label(String.localized("Update available: %@", arguments: available.version), systemImage: "arrow.up.circle.fill")
						.foregroundStyle(Color.accentColor)
					Spacer()
					Button(.localized("View")) { _selected = available }
						.font(.subheadline.bold())
				}
			} else if let latest = _manager.latest {
				HStack {
					VStack(alignment: .leading, spacing: 2) {
						Text(.localized("Latest Release"))
						Text(latest.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
					}
					Spacer()
					Button(latest.isInstalled ? .localized("Reinstall") : .localized("Install")) { _selected = latest }
						.font(.subheadline.bold())
				}
			}
			Button {
				Task { await _manager.check() }
			} label: {
				HStack {
					Text(.localized("Check for Updates"))
					Spacer()
					if _manager.isChecking { ProgressView() }
				}
			}
			.disabled(_manager.isChecking)
		}
	}

	// MARK: Options

	private var _optionsSection: some View {
		Group {
			NBSection(.localized("Options")) {
				Toggle(.localized("Automatic Update Checks"), isOn: $_autoCheck)
				Picker(.localized("Install Method"), selection: $_method) {
					Text(.localized("Server")).tag(0)
					Text(.localized("IDevice")).tag(1)
				}
				Picker(.localized("Signing Certificate"), selection: $_certIndex) {
					Text(.localized("Selected Certificate")).tag(-1)
					ForEach(Array(_certificates.enumerated()), id: \.offset) { index, cert in
						Text(_certName(cert)).tag(index)
					}
				}
			} footer: {
				VStack(alignment: .leading, spacing: 6) {
					Text(_method == 0
						 ? .localized("Server: your certificate is sent over HTTPS, the update is signed remotely, and iOS installs it. No pairing file needed.")
						 : .localized("IDevice: the update is signed on-device and installed over a pairing file."))
					Text(.localized("Sign with the certificate you first installed VexSign with, or iOS won't update it in place."))
				}
			}

			if _method == 1 {
				Section {
					Button {
						UIApplication.open("localdevvpn://enable?scheme=vexsign")
					} label: {
						Label(.localized("Connect to LocalDevVPN"), systemImage: "link")
					}
					Button {
						UIApplication.open("https://apps.apple.com/us/app/localdevvpn/id6755608044")
					} label: {
						Label(.localized("Download LocalDevVPN"), systemImage: "arrow.down.app")
					}
					if !_manager.hasPairing {
						Label(.localized("IDevice updates need a pairing file. Set it up in Installation settings, or switch to Server."), systemImage: "exclamationmark.triangle.fill")
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				} footer: {
					Text(.localized("IDevice updates need the loopback VPN connected. Enable LocalDevVPN, then update."))
				}
			} else if !_manager.isServerConfigured {
				Section {
					Label(SelfUpdateBlocker.serverNotConfigured.message, systemImage: "exclamationmark.triangle.fill")
						.font(.footnote)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
					if _manager.hasPairing {
						Button(.localized("Install Updates with IDevice")) { _manager.adopt(.idevice) }
					} else {
						NavigationLink {
							NBList(.localized("Tunnel")) { TunnelView() }
						} label: {
							Label(.localized("Pairing file and VPN setup"), systemImage: "link")
						}
					}
				} footer: {
					Text(.localized("Server updates need an address that answers /vexsign/sign. Enter one below, or import a pairing file and use IDevice."))
				}
			}
			_serverAddressSection
		}
	}

	// MARK: Updater server address

	/// The build can ship without a bundled `SelfUpdateConfig.plist`; before this field existed the
	/// only answer was a warning that the server "isn't available in this build", with no way to
	/// supply one.
	private var _serverAddressSection: some View {
		NBSection(.localized("Updater Server Address")) {
			HStack {
				TextField(.localized("https://updater.example.com"), text: $_serverAddressDraft)
					.keyboardType(.URL)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.submitLabel(.done)
					.onSubmit(_saveServerAddress)
				if !_serverAddressDraft.isEmpty {
					Button {
						_serverAddressDraft = ""
					} label: {
						Image(systemName: "xmark.circle.fill")
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
					.accessibilityLabel(Text(.localized("Clear")))
				}
			}
			Button(.localized("Save Address")) { _saveServerAddress() }
				.disabled(_serverAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines) == _manager.configuredServerAddress)
			HStack {
				Text(.localized("Status"))
				Spacer()
				Text(verbatim: _manager.isServerConfigured ? String.localized("Configured") : String.localized("Not configured"))
					.foregroundStyle(_manager.isServerConfigured ? Color.accentColor : Color.secondary)
			}
			if _manager.hasServerAddressOverride {
				Button(.localized("Remove Saved Address")) {
					_serverAddressDraft = ""
					_manager.setServerBaseURL(nil)
					_serverAddressError = nil
				}
			}
			if let error = _serverAddressError {
				Label(error, systemImage: "exclamationmark.triangle.fill")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		} footer: {
			Text(.localized("Only an http(s) address is accepted; https is assumed when the scheme is left out. Leave this empty to use the address compiled into this build."))
		}
	}

	private func _saveServerAddress() {
		let trimmed = _serverAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard _manager.setServerBaseURL(trimmed) else {
			_serverAddressError = .localized("Enter a valid address, for example https://updater.example.com.")
			return
		}
		_serverAddressError = nil
		// Show the normalised value (scheme added, trailing slash removed) rather than what was typed.
		_serverAddressDraft = _manager.configuredServerAddress
	}

	// MARK: Ignored

	private var _ignoredSection: some View {
		NBSection(.localized("Ignored Versions")) {
			ForEach(Array(_manager.ignoredVersions).sorted { SelfUpdateManager.compare($0, $1) == .orderedDescending }, id: \.self) { version in
				HStack {
					Text(version)
					Spacer()
					Button(.localized("Resume")) { _manager.unignore(version) }
						.font(.subheadline)
				}
			}
		}
	}

	private func _certName(_ cert: CertificatePair) -> String {
		cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? .localized("Unknown")
	}
}
