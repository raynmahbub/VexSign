//
//  CleanupView.swift
//  VexSign
//
//  Settings → Auto Cleanup. Every cleanup the app can do on its own, in one place, with a master
//  switch and a manual "Clean Now" for good measure.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct CleanupView: View {
	@ObservedObject private var _manager = CleanupManager.shared
	@ObservedObject private var _history = CleanupHistoryStore.shared

	@AppStorage(CleanupManager.Key.enabled) private var _isEnabled: Bool = true
	@AppStorage(CleanupManager.Key.oneTapInstall) private var _oneTapInstall: Bool = false
	@AppStorage(StorageRules.keepOnlyLatestKey) private var _keepOnlyLatest: Bool = false
	@AppStorage(StorageRules.warnGigabytesKey) private var _warnGB: Int = 0

	@AppStorage(CleanupManager.Key.deleteAfterInstall) private var _deleteAfterInstall: Bool = false
	@AppStorage(CleanupManager.Key.deleteDownloadedIPA) private var _deleteDownloadedIPA: Bool = false

	@AppStorage(CleanupManager.Key.deleteSourceAfterSign) private var _deleteSourceAfterSign: Bool = false
	@AppStorage(CleanupManager.Key.deleteSignedAfterSign) private var _deleteSignedAfterSign: Bool = false

	@AppStorage(CleanupManager.Key.clearCache) private var _clearCache: Bool = false
	@AppStorage(CleanupManager.Key.clearTemporary) private var _clearTemporary: Bool = false
	@AppStorage(CleanupManager.Key.removeLeftovers) private var _removeLeftovers: Bool = false
	@AppStorage(CleanupManager.Key.clearArchives) private var _clearArchives: Bool = false

	@State private var _reclaimable: Int64 = 0
	@State private var _isCleaning = false

	// MARK: Body
	var body: some View {
		NBList(.localized("Auto Cleanup")) {
			_masterSection
			_pipelineSection

			if _isEnabled {
				_afterInstalling
				_afterSigning
				_storage
			}

			_rulesSection
			_nowSection
			_lastRunSection
			_historySection
		}
		.task { await _refreshReclaimable() }
		.onChange(of: _isEnabled) { _, _ in Task { await _refreshReclaimable() } }
		.onChange(of: _clearCache) { _, _ in Task { await _refreshReclaimable() } }
		.onChange(of: _clearTemporary) { _, _ in Task { await _refreshReclaimable() } }
		.onChange(of: _removeLeftovers) { _, _ in Task { await _refreshReclaimable() } }
		.onChange(of: _clearArchives) { _, _ in Task { await _refreshReclaimable() } }
	}
}

// MARK: - Sections
extension CleanupView {
	@ViewBuilder
	private var _masterSection: some View {
		Section {
			Toggle(.localized("Auto Cleanup"), isOn: $_isEnabled)
		} footer: {
			Text(.localized("Runs the options below by itself every time signing or installing finishes, so nothing has to be deleted or cleaned up by hand. Turn this off to keep every app and cache."))
		}
	}

	@ViewBuilder
	private var _pipelineSection: some View {
		NBSection(.localized("Automation")) {
			Toggle(isOn: Binding(
				get: { _oneTapInstall || _manager.isOneTapInstall },
				set: { _manager.setOneTapInstall($0) }
			)) {
				Label(.localized("One-Tap Install"), systemImage: "wand.and.stars")
			}
		} footer: {
			VStack(alignment: .leading, spacing: 6) {
				Text(.localized("Import or download an app and VexSign signs it, installs it, deletes the app from your library and clears the caches — no taps in between."))

				if !AutoSignManager.canSign {
					Text(.localized("Import a certificate first, otherwise signing cannot run on its own."))
						.foregroundStyle(.orange)
				}
			}
		}
	}

	@ViewBuilder
	private var _afterInstalling: some View {
		NBSection(.localized("After Installing")) {
			Toggle(.localized("Delete Installed App"), isOn: $_deleteAfterInstall)
			Toggle(.localized("Delete Downloaded IPA"), isOn: $_deleteDownloadedIPA)
		} footer: {
			Text(.localized("The app stays installed on your device — only the copy in VexSign's library is removed. The IPA is the file VexSign downloaded or imported before signing."))
		}
	}

	@ViewBuilder
	private var _afterSigning: some View {
		NBSection(.localized("After Signing")) {
			Toggle(.localized("Delete Unsigned App"), isOn: $_deleteSourceAfterSign)
			Toggle(.localized("Delete Signed App"), isOn: $_deleteSignedAfterSign)
		} footer: {
			VStack(alignment: .leading, spacing: 6) {
				Text(.localized("The unsigned app is the file you imported; it is only needed to produce the signed copy."))

				Text(.localized("Delete Signed App applies when you sign an app that is already signed: the copy you started from is removed once the new signed copy is in your library. The new copy is not deleted after signing."))
			}
		}
	}

	@ViewBuilder
	private var _storage: some View {
		NBSection(.localized("Storage")) {
			Toggle(.localized("Clear Caches"), isOn: $_clearCache)
			Toggle(.localized("Clear Temporary Files"), isOn: $_clearTemporary)
			Toggle(.localized("Remove Leftovers"), isOn: $_removeLeftovers)
			Toggle(.localized("Delete Exported IPAs"), isOn: $_clearArchives)
		} footer: {
			Text(.localized("Caches are icons and web data, rebuilt as you browse. Temporary files and leftovers are work files from imports and signings. Exported IPAs are the ones saved every time you export or share an app."))
		}
	}

	@ViewBuilder
	private var _nowSection: some View {
		Section {
			Button {
				_clean()
			} label: {
				HStack {
					Label(.localized("Clean Storage Now"), systemImage: "sparkles")
					Spacer()
					if _isCleaning {
						ProgressView()
					} else if _reclaimable > 0 {
						Text(verbatim: _reclaimable.formattedFileSize)
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
			}
			.disabled(_isCleaning)

			Button(role: .destructive) {
				DestructiveConfirm.present(
					title: .localized("Clear IPA Explorer Workspaces?"),
					message: .localized("Every IPA you unpacked in the IPA Explorer will be deleted. Apps in your library are not touched.")
				) {
					IPAWorkspace.discardAll()
					Toast.success(.localized("Workspaces cleared"), systemImage: "trash")
				}
			} label: {
				Label(.localized("Clear IPA Explorer Workspaces"), systemImage: "doc.zipper")
			}
		} footer: {
			Text(.localized("Clears the storage options above straight away. Nothing installed on your device is ever touched."))
		}
	}

	@ViewBuilder
	private var _lastRunSection: some View {
		Section {
			LabeledContent(.localized("Last Cleanup")) {
				if let date = _manager.lastRunDate {
					Text(verbatim: "\(date.formatted(date: .abbreviated, time: .shortened)) · \(_manager.lastFreedBytes.formattedFileSize)")
				} else {
					Text(.localized("Never"))
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	@ViewBuilder
	private var _rulesSection: some View {
		NBSection(.localized("Rules")) {
			Toggle(.localized("Keep only the newest signed copy"), isOn: $_keepOnlyLatest)
			Stepper(value: $_warnGB, in: 0...64) {
				HStack {
					Text(.localized("Warn when storage exceeds"))
					Spacer()
					Text(verbatim: _warnGB == 0 ? .localized("Off") : .localized("%lld GB", arguments: _warnGB))
						.foregroundStyle(.secondary)
				}
			}
		} footer: {
			Text(.localized("When an app has several signed copies, the automatic sweep keeps the highest version and removes the rest. Among copies of the same version it keeps the one added last. Certificates and pairing files are never auto-deleted. The warning is a toast on launch, not a deletion."))
		}
	}

	@ViewBuilder
	private var _historySection: some View {
		if !_history.entries.isEmpty {
			NBSection(.localized("History")) {
				ForEach(_history.entries.prefix(20)) { entry in
					HStack {
						VStack(alignment: .leading, spacing: 1) {
							Text(verbatim: entry.date.formatted(date: .abbreviated, time: .shortened))
								.font(.subheadline.weight(.medium))
							if !entry.removedApps.isEmpty {
								Text(verbatim: entry.removedApps.joined(separator: ", "))
									.font(.caption)
									.foregroundStyle(.secondary)
									.lineLimit(1)
							}
						}
						Spacer()
						Text(verbatim: entry.freedBytes.formattedFileSize)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				Button(role: .destructive) {
					_history.clear()
				} label: {
					Label(.localized("Clear History"), systemImage: "trash")
				}
			} footer: {
				Text(verbatim: String.localized("%@ freed across %lld recorded cleanups.", arguments: _history.totalFreedInHistory.formattedFileSize, _history.entries.count))
			}
		}
	}
}

// MARK: - Actions
extension CleanupView {
	private func _clean() {
		_isCleaning = true
		NBHaptic.tap()

		let summary = _manager.cleanNow()

		if let notice = summary.deferralNotice {
			// Temporary files and leftovers are left alone while something is signing or
			// installing. Said whether or not anything else was cleaned: the button promises the
			// storage options above, and "Nothing to clean up" would not be true.
			Toast.info(notice, systemImage: "hourglass", duration: .long)
		} else if summary.isIdle {
			Toast.info(.localized("Nothing to clean up"), systemImage: "checkmark.circle")
		}

		Task {
			await _refreshReclaimable()
			_isCleaning = false
		}
	}

	private func _refreshReclaimable() async {
		let bytes = _manager.reclaimableBytes()
		await MainActor.run { _reclaimable = bytes }
	}
}
