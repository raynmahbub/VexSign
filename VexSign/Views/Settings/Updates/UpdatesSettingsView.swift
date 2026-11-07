//
//  UpdatesSettingsView.swift
//  VexSign
//
//  Created by VexSign Team on 05.07.2026.
//

import SwiftUI
import NimbleViews
import UIKit
import UserNotifications
import NimbleExtensions

struct UpdatesSettingsView: View {
	@ObservedObject private var _manager = SelfUpdateManager.shared
	@AppStorage("VexSign.selfUpdateAutoCheck") private var _autoCheck: Bool = true
	@AppStorage("VexSign.selfUpdateCertIndex") private var _certIndex: Int = -1
	@AppStorage("VexSign.selfUpdateMethod") private var _method: Int = 0
	@AppStorage(AppStoreUpdateTracker.enabledKey) private var _appStoreTracking: Bool = false
	@AppStorage(SelfUpdateNotifier.enabledKey) private var _notifyOnRelease: Bool = true

	@State private var _selected: SelfUpdateRelease?
	@State private var _serverAddressDraft: String = ""
	@State private var _serverAddressError: String?
	@State private var _notificationAuthorization: UNAuthorizationStatus = .notDetermined
	@ObservedObject private var _appStoreTracker = AppStoreUpdateTracker.shared

	private let _certificates = Storage.shared.getAllCertificates()

	var body: some View {
		NBList(.localized("Updates")) {
			_statusSection
			_optionsSection
			_notificationSection
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
			Task { await _refreshNotificationAuthorization() }
		}
		.onChange(of: _method) { _ in _manager.refreshConfiguration() }
		.onChange(of: _notifyOnRelease) { enabled in
			guard enabled else { return }
			// Ask here, where the person just said yes — never from a background check.
			Task { await _requestNotificationPermission() }
		}
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
			if _manager.isChecking {
				Label(.localized("Checking for updates…"), systemImage: "arrow.clockwise")
					.foregroundStyle(.secondary)
			} else if let error = _manager.checkError {
				VStack(alignment: .leading, spacing: 5) {
					Label(.localized("Couldn't check for updates"), systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange)
					Text(error)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			} else if let available = _manager.available {
				HStack {
					Label(String.localized("Update available: %@", arguments: available.version), systemImage: "arrow.up.circle.fill")
						.foregroundStyle(Color.accentColor)
					Spacer()
					Button(.localized("View")) { _selected = available }
						.font(.subheadline.bold())
				}
			} else if _manager.hasChecked, let latest = _manager.latestSemver {
				let comparison = SelfUpdateManager.compare(latest.version, Bundle.main.version)
				let isComparableBuild = SelfUpdateManager.isSemver(Bundle.main.version)
				let isIgnoredUpdate = isComparableBuild
					&& comparison == .orderedDescending
					&& _manager.ignoredVersions.contains(latest.version)
				let statusTitle: String = {
					if !isComparableBuild { return .localized("Version comparison is unavailable for this build") }
					if isIgnoredUpdate { return String.localized("Update %@ is ignored", arguments: latest.version) }
					if comparison == .orderedDescending { return String.localized("Newer release found: %@", arguments: latest.version) }
					return .localized("You're up to date")
				}()
				let statusIcon = !isComparableBuild ? "questionmark.circle" : isIgnoredUpdate ? "bell.slash" : comparison == .orderedDescending ? "arrow.up.circle.fill" : "checkmark.circle.fill"
				VStack(alignment: .leading, spacing: 3) {
					Label(statusTitle, systemImage: statusIcon)
						.foregroundStyle(!isComparableBuild || isIgnoredUpdate ? Color.secondary : comparison == .orderedDescending ? Color.accentColor : Color.green)
					Text(String.localized("Latest stable release: %@", arguments: latest.version))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} else if _manager.hasChecked {
				Label(.localized("No stable release found"), systemImage: "info.circle")
					.foregroundStyle(.secondary)
			}

			if !_manager.isChecking, _manager.checkError == nil, _manager.available == nil,
			   let latest = _manager.latest {
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

	// MARK: Notifications

	/// iOS cannot tell an app when a GitHub release is published — there is no push service here,
	/// and background work is scheduled by the system. The alert is therefore posted by the update
	/// checks VexSign already runs, and the copy says so instead of promising an instant push.
	private var _notificationSection: some View {
		NBSection(.localized("Release Notifications")) {
			Toggle(.localized("Notify Me About New Releases"), isOn: $_notifyOnRelease)
			if _notifyOnRelease && !_canDeliverNotifications {
				Label(_notificationIssue, systemImage: "bell.slash.fill")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Button(.localized("Open iOS Notification Settings")) {
					UIApplication.open(UIApplication.openSettingsURLString)
				}
			}
		} footer: {
			Text(.localized("A one-time local alert the first time a newer VexSign release appears. It is posted by the update check on launch, in this screen, or during a scheduled automation pass — iOS decides when background checks run, so it is not an instant push."))
		}
	}

	private var _canDeliverNotifications: Bool {
		_notificationAuthorization == .authorized || _notificationAuthorization == .provisional
	}

	private var _notificationIssue: String {
		_notificationAuthorization == .denied
			? .localized("Notifications are turned off for VexSign in iOS Settings, so the release alert cannot be shown.")
			: .localized("Allow notifications so the release alert can be shown.")
	}

	@MainActor
	private func _refreshNotificationAuthorization() async {
		let settings = await UNUserNotificationCenter.current().notificationSettings()
		_notificationAuthorization = settings.authorizationStatus
	}

	/// Asked only when the switch is turned on, never from a background check.
	@MainActor
	private func _requestNotificationPermission() async {
		do {
			_ = try await UNUserNotificationCenter.current()
				.requestAuthorization(options: [.alert, .sound, .badge])
		} catch {
			FileLogger.log("Notification permission request failed: \(error.localizedDescription)", category: "update")
		}
		await _refreshNotificationAuthorization()
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
