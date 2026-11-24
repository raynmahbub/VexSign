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
	@AppStorage(AppStoreUpdateTracker.enabledKey) private var _appStoreTracking: Bool = false
	@AppStorage(SelfUpdateNotifier.enabledKey) private var _notifyOnRelease: Bool = true

	@State private var _selected: SelfUpdateRelease?
	@State private var _notificationAuthorization: UNAuthorizationStatus = .notDetermined
	@ObservedObject private var _appStoreTracker = AppStoreUpdateTracker.shared


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
			_manager.refreshConfiguration()
			Task { await _refreshNotificationAuthorization() }
		}
		.onChange(of: _notifyOnRelease) { _, enabled in
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
					Button(.localized("Review update")) { _selected = available }
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
					Button(.localized("Review release")) { _selected = latest }
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
                Text(.localized("Release checks fetch public version metadata only. Downloading an IPA is not installation. Sign it locally in Library and update VexSign using an eligible external installer; automatic self-replacement is not supported in this build."))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(SelfUpdateBlocker.remoteSigningDisabled.message)
                    .font(.footnote).foregroundStyle(.orange)
                Text(SelfUpdateBlocker.pairedRouteUnavailable.message)
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink {
                    NBList(.localized("Device bootstrap")) { TunnelView() }
                } label: {
                    Label(.localized("Review bootstrap limitations"), systemImage: "cable.connector")
                }
            }
            if _manager.hasServerAddressOverride {
                NBSection(.localized("Inactive legacy updater settings")) {
                    Button(.localized("Remove Saved Address"), role: .destructive) {
                        _manager.setServerBaseURL(nil)
                    }
                } footer: {
                    Text(.localized("The saved updater address is not used for signing or uploads. Removing it does not delete local certificates or alter their Keychain passwords."))
                }
            }
        }
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

}
