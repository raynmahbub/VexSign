//
//  BackupView.swift
//  VexSign
//
//  Created by VexSign Team
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct BackupView: View {
	@State private var _isWorking = false
	@State private var _showRestorePassword = false
	@State private var _password = ""
	@State private var _pendingImportURL: URL?
	@State private var _archive: BackupArchive?
	@State private var _showExportPicker = false
	@State private var _pendingExport: (components: BackupComponents, password: String)?
	@State private var _pendingSummary: BackupRestoreSummary?
	@State private var _showLegacyWarning = false

	// MARK: Body
	var body: some View {
		NBList(.localized("Backup & Restore")) {
			Section {
				Button {
					_pendingExport = nil
					_showExportPicker = true
				} label: {
					Label(.localized("Create Backup"), systemImage: "square.and.arrow.up")
				}
			} footer: {
				Text(.localized("Saves selected components, including signed and imported app bundles. Backups use streaming encryption with an 8 GiB safe extraction limit; installed app data is not included."))
			}

			Section {
				Button {
					DocumentPicker.open([.vexBackup], folder: .backups) { urls in
						guard let url = urls.first else { return }
						_pendingImportURL = url
						_password = ""
						if BackupCrypto.isLegacyPlaintext(url) {
							// Written by an older version without encryption. It still
							// restores, but the user should know what it is first.
							_showLegacyWarning = true
						} else if BackupCrypto.needsPassword(url) {
							_showRestorePassword = true
						} else {
							_openBackup()
						}
					}
				} label: {
					Label(.localized("Restore from Backup"), systemImage: "square.and.arrow.down")
				}
			} footer: {
				Text(.localized("Open a backup file, then pick what comes back. Backups made without a password are encrypted for this device and cannot be restored on another one."))
			}
		}
		.disabled(_isWorking)
		.animation(.easeInOut(duration: 0.2), value: _isWorking)
		.overlay { _workingOverlay }
		.sheet(isPresented: $_showExportPicker, onDismiss: _runExport) {
			let available = BackupManager.shared.availableComponents()
			BackupComponentsView(
				title: .localized("Create Backup"),
				confirmTitle: .localized("Create"),
				available: available.components,
				counts: available.counts,
				footer: .localized("Choose what to include in this backup."),
				passwordFooter: .localized("Every backup is encrypted. With a password it can be restored on another device; without one it stays readable only on this one. A backup that includes certificates needs a password of at least %lld characters.", arguments: Int64(BackupCrypto.minimumPasswordLength)),
				enforcesPasswordForCertificates: true,
				onConfirm: { _pendingExport = ($0, $1) }
			)
		}
		.sheet(item: $_archive, onDismiss: _presentRestoreComplete) { archive in
			BackupComponentsView(
				title: .localized("Restore from Backup"),
				confirmTitle: .localized("Restore"),
				available: archive.contents,
				counts: _archiveCounts(archive),
				detail: _archiveDetail(archive),
				footer: .localized("Nothing is deleted. Anything already here is skipped."),
				onConfirm: { components, _ in
                    _isWorking = true
                    Task {
                        do {
                            _pendingSummary = try await BackupManager.shared.restore(archive, components: components)
                            _isWorking = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { _presentRestoreComplete() }
                        } catch {
                            _isWorking = false
                            Toast.error(error.localizedDescription, duration: .long)
                        }
                    }
				}
			)
		}
		.alert(.localized("Unencrypted backup"), isPresented: $_showLegacyWarning) {
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("Restore Anyway")) { _openBackup() }
		} message: {
			Text(.localized("This file was made by an older version of VexSign and is not encrypted. If it includes certificates, it holds private keys in the clear. Delete it once you have restored what you need."))
		}
		.alert(.localized("Backup Password"), isPresented: $_showRestorePassword) {
			SecureField(.localized("Password"), text: $_password)
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("Continue")) { _openBackup() }
		} message: {
			Text(.localized("Enter the password this backup was encrypted with."))
		}
	}

	@ViewBuilder
	private var _workingOverlay: some View {
		if _isWorking {
			ZStack {
				Color(.systemBackground).opacity(0.6).ignoresSafeArea()
				VStack(spacing: 14) {
					ProgressView()
					Text(.localized("Working…"))
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				.padding(24)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
			}
			.transition(.opacity)
		}
	}

	private func _archiveDetail(_ archive: BackupArchive) -> String {
		let created = String.localized(
			"Created %@ · VexSign %@",
			arguments: archive.manifest.createdAt.formatted(date: .abbreviated, time: .shortened),
			archive.manifest.appVersion
		)
		return created + "\n" + String.localized("VexSign backup schema %lld. Other signers’ backup formats are not supported. Restoring a library copy does not restore an installed app’s private data or prove installation.", arguments: archive.manifest.version) + "\n" + archive.integrity.summary
	}

	private func _archiveCounts(_ archive: BackupArchive) -> [BackupComponents: Int] {
		BackupComponents.ordered.reduce(into: [:]) { result, component in
			result[component] = archive.manifest.count(of: component)
		}
	}

	private func _runExport() {
		guard let pending = _pendingExport else { return }
		_pendingExport = nil
		_isWorking = true
		Task {
			do {
				let url = try await BackupManager.shared.makeBackup(
					password: pending.password,
					components: pending.components
				)
				_isWorking = false
				Toast.success(.localized("Backup created"))
				DocumentPicker.export([url])
			} catch {
				_isWorking = false
				Toast.error(error.localizedDescription)
			}
		}
	}

	private func _openBackup() {
		guard let url = _pendingImportURL else { return }
		let password = _password
		_isWorking = true
		Task {
			do {
				let archive = try await BackupManager.shared.open(url, password: password)
				_isWorking = false
				guard !archive.contents.isEmpty else {
					Toast.error(.localized("This backup is empty."))
					return
				}
				_archive = archive
			} catch {
				_isWorking = false
				Toast.error(error.localizedDescription)
			}
		}
	}

	private func _presentRestoreComplete() {
		guard let summary = _pendingSummary else { return }
		_pendingSummary = nil

		let needsRestart = !summary.restored.intersection([.settings, .certificates]).isEmpty
		let message = needsRestart
			? summary.lines.joined(separator: "\n") + "\n\n" + .localized("VexSign will restart to apply the backup.")
			: summary.lines.joined(separator: "\n")

		UIAlertController.showAlert(
			title: .localized("Restore Complete"),
			message: message,
			actions: [
				needsRestart
				? UIAlertAction(title: .localized("Restart"), style: .default) { _ in
					UIApplication.shared.suspendAndReopen()
				}
				: UIAlertAction(title: .localized("Done"), style: .default, handler: nil)
			]
		)
	}
}
