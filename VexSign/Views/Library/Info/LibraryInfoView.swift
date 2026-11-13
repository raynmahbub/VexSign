//
//  LibraryInfoView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 14.04.2025.
//

import SwiftUI
import NimbleViews
import Zsign
import UIKit
import IDeviceSwift
import NimbleExtensions

// MARK: - View
struct LibraryInfoView: View {
	var app: AppInfoPresentable
	@State private var _displayedDescription: String?
	@State private var _isClonePresenting = false
    @State private var _renewalReadiness: RenewalReadiness?
    @State private var _renewalInstallation: InstallMethodReport?
    @State private var _renewalInstallationError: String?
    @State private var _renewalCheckedAt: Date?
    @State private var _renewalIssues: [PreflightIssue] = []
    @State private var _isResigning = false
    @ObservedObject private var _tasks = UnifiedTaskCenter.shared
    @State private var _isCompanionPresenting = false
    @ObservedObject private var _lockManager = AppLockManager.shared
	@ObservedObject private var _appStoreTracker = AppStoreUpdateTracker.shared
	@ObservedObject private var _status = LibraryStatusStore.shared

	// MARK: Body
    var body: some View {
		NBNavigationView(app.name ?? "", displayMode: .inline) {
			List {
				Section {} header: {
					FRAppIconView(app: app)
						.frame(maxWidth: .infinity, alignment: .center)
				}

                _workspaceStatusSection()
                _renewalReadinessSection()
				_infoSection(for: app)
				_signatureSection(for: app)
				_certSection(for: app)
				_bundleSection(for: app)
				_executableSection(for: app)

				_resignSection()
				_cloneSection()
                Section {
                    Button {
                        _openCompanionWorkflow()
                    } label: {
                        Label(.localized("SideStore & LiveContainer"), systemImage: "arrow.triangle.branch")
                    }
                } footer: {
                    Text(.localized("Prepare this library app as an IPA for LiveContainer, or open SideStore for Apple-account setup and renewal. No credentials are shared with VexSign."))
                }
				_appStoreSection()

				// Only a signed copy can have been installed by VexSign under this identifier.
				if app.isSigned, let identifier = app.identifier, !identifier.isEmpty {
					DeviceAppRemovalSection(
						bundleIdentifier: identifier,
						name: app.name ?? identifier
					)
				}

				Section {
					_linksSection(for: app)
					Button(.localized("Open in Files"), systemImage: "folder") {
	                        if let url = Storage.shared.getUuidDirectory(for: app)?.toSharedDocumentsURL() {
                            UIApplication.open(url)
                        }
					}
				}
			}
			.toolbar {
				NBToolbarButton(role: .close)
			}
		}
		.onAppear {
			_displayedDescription = app.appDescription
		}
        .sheet(isPresented: $_isCompanionPresenting) {
            NavigationStack {
                CompanionSigningWorkflowView(libraryApp: AnyApp(base: app))
            }
        }
		.sheet(isPresented: $_isClonePresenting) {
			AppCloneSheet(app: app)
		}
		.task {
			LibraryStatusStore.shared.request(app, force: true)
		}
		.task {
			guard AppStoreUpdateTracker.isEnabled else { return }
			await _appStoreTracker.refresh(apps: [app])
		}
    }
}

// MARK: - Extension: View
extension LibraryInfoView {
    @ViewBuilder
    private func _workspaceStatusSection() -> some View {
        let status = _status.status(for: app)
        Section {
            Label(.localized("Stored in Library"), systemImage: "archivebox")
            LabeledContent(.localized("Library copy"), value: app.isSigned ? String.localized("Signed copy") : String.localized("Imported copy"))
            LabeledContent(.localized("Device installation"), value: status.installationTitle)
            if status.guest != .unavailable {
                LabeledContent(.localized("Embedded container"), value: status.guest.title)
                Text(.localized("A container import does not prove signing or a successful guest launch, and is not an iOS device installation."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let expiry = status.expiresAt {
                LabeledContent(.localized("Bundle signature expiry")) { Text(expiry, style: .date) }
            }
            _signingRecordRows()
        } header: { Text(.localized("Workspace status")) } footer: {
            Text(.localized("A stored or signed copy does not prove installation. Unknown means VexSign could not verify the current device state."))
        }
    }

    /// What signing has on record for this copy.
    ///
    /// A run is recorded against the copy it was started from, and the copy it produced is a
    /// different record. This screen used to show the newest run started from the copy under
    /// "Last recorded signing result", so a signed copy said nothing about how it was signed -
    /// and after a re-sign that failed it said "Failed", although a failed run never changes the
    /// copy it started from. The two facts are shown apart, each under what it is.
    @ViewBuilder
    private func _signingRecordRows() -> some View {
        let records = _tasks.signingRecords(forCopy: app.uuid)
        if app.isSigned {
            if let produced = records.produced {
                LabeledContent(.localized("Signing result for this copy"), value: produced.displayPhaseTitle)
                Text(produced.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                // The signing sheet is dismissed as soon as a run succeeds, so this is where the
                // execution trace stays readable: which steps the engine actually reported, and
                // whether it verified the signature it produced.
                if let trace = produced.context?.signingTrace, !trace.isEmpty {
                    SigningWorkflowView(snapshot: SigningWorkflowSnapshot(trace: trace))
                }
            }
            if let attempt = records.unfinishedAttempt {
                LabeledContent(.localized("Latest re-sign attempt from this copy"), value: attempt.phase.title)
                Text(attempt.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                if let reason = attempt.errorText, !reason.isEmpty {
                    Text(LogRedaction.redact(reason))
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if attempt.phase.isTerminal {
                    Text(.localized("That attempt did not change this copy."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let trace = attempt.context?.signingTrace, !trace.isEmpty {
                    SigningWorkflowView(
                        snapshot: SigningWorkflowSnapshot(trace: trace, running: !attempt.phase.isTerminal),
                        title: .localized("Steps of that attempt"),
                        identifier: A11y.Signing.attemptWorkflow
                    )
                }
            }
        } else if let task = records.latestStarted {
            // An imported copy is only ever a source, so the newest run started from it is the
            // whole story. Its wording is unchanged.
            LabeledContent(.localized("Last recorded signing result"), value: task.phase.title)
            Text(task.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            if let trace = task.context?.signingTrace, !trace.isEmpty {
                SigningWorkflowView(snapshot: SigningWorkflowSnapshot(trace: trace))
            }
        }
    }

    @ViewBuilder
    private func _renewalReadinessSection() -> some View {
        Section {
            Button(.localized("Check retained renewal inputs"), systemImage: "checklist") {
                _refreshRenewalReadiness()
            }
            if let report = _renewalReadiness {
                Text(report.retainedInputsAvailable
                     ? String.localized("Retained signing inputs available")
                     : String.localized("Review required before repeat signing"))
                LabeledContent(.localized("Library bundle"), value: report.hasLibraryBundle ? String.localized("Present") : String.localized("Missing"))
                LabeledContent(.localized("Saved signing settings"), value: report.hasSavedSettings ? String.localized("Present") : String.localized("Missing"))
                Text(_renewalIdentityDescription(report.identity)).font(.caption)
                ForEach(_renewalIssues) { issue in
                    VStack(alignment: .leading) {
                        Text(issue.title).font(.caption.bold())
                        Text(LogRedaction.redact(issue.detail)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let installationError = _renewalInstallationError {
                    Text(installationError).font(.caption).foregroundStyle(.orange)
                } else if let installation = _renewalInstallation {
                    LabeledContent(.localized("Selected installation method"), value: installation.method.title)
                    switch installation.readiness {
                    case .ready:
                        Text(.localized("Installation prerequisites available; successful installation has not been verified."))
                    case .missing(let reason), .unavailable(let reason), .unknown(let reason):
                        Text(reason).font(.caption)
                    }
                } else {
                    Text(.localized("No recognized installation method is selected. Review Installation settings."))
                }
                if let checkedAt = _renewalCheckedAt {
                    Text(checkedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text(.localized("Renewal readiness")) } footer: {
            Text(.localized("This checks retained local inputs only. It does not verify private-key usability, provisioning compatibility, source freshness, unattended renewal, or an update that preserves installed app data. Signing and installation gates still apply. Refresh after changing settings."))
        }
    }

    private func _renewalIdentityDescription(_ identity: RenewalIdentityReadiness) -> String {
        switch identity {
        case .missing: return .localized("No signing certificate is available.")
        case .expired: return .localized("The resolved signing certificate has expired.")
        case .revoked: return .localized("The resolved signing certificate is marked revoked.")
        case .fallback: return .localized("The saved certificate is unavailable. The current selection would be used instead; signing identity is not preserved.")
        case .currentSelection: return .localized("No fixed certificate was saved. Repeat signing uses the current selection; identity continuity is not established.")
        case .savedIdentity: return .localized("The saved certificate record is available. File presence and expiry do not prove that signing or renewal will work.")
        }
    }

    @MainActor
    private func _refreshRenewalReadiness() {
        let profile = SigningProfileStore.shared.profile(forBundleID: app.identifier)
        let certificate = SigningProfileStore.shared.certificate(for: profile)
        let bundleExists = Storage.shared.getAppDirectory(for: app).map {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        } ?? false
        _renewalReadiness = RenewalReadiness(RenewalReadinessInputs(
            hasLibraryBundle: bundleExists, hasSavedSettings: profile != nil,
            savedCertificateUUID: profile?.certificateUUID, resolvedCertificateUUID: certificate?.uuid,
            hasCertificate: certificate != nil,
            certificateExpired: (certificate?.expiration).map { $0 <= Date() } ?? false,
            certificateRevoked: certificate?.revoked == true
        ))
        _renewalIssues = PreflightChecks.run(app: app, options: (profile?.options ?? Options.batchBase).resolved(for: app), certificate: certificate).issues
        let inputs = InstallPreflightInputs(
            hasServerCertificate: LocalTLSIdentity.current() != nil,
            pairing: PairingRecordInspector.inspect(fileAt: URL(fileURLWithPath: HeartbeatManager.pairingFile())),
            trollStoreDetected: TrollStoreHandoff.installedByTrollStore(),
            hasTrustedServerCertificate: LocalTLSIdentity.isSystemTrusted(),
            hasEmbeddedRuntime: EmbeddedContainerRuntime.isAvailable
        )
        _renewalInstallationError = nil
        do {
            let pipeline = try SigningModeManager.shared.pipeline(for: app)
            _renewalInstallation = InstallMethodReport(
                method: pipeline.installMethod,
                readiness: InstallPreflight.readiness(for: pipeline.installMethod, inputs)
            )
        } catch {
            _renewalInstallation = nil
            _renewalInstallationError = error.localizedDescription
        }
        _renewalCheckedAt = Date()
    }

    private func _openCompanionWorkflow() {
        if let uuid = app.uuid, _lockManager.isAppLocked(uuid), !_lockManager.isSessionUnlocked(uuid) {
            _lockManager.authenticateForApp(uuid: uuid, name: app.name ?? .localized("Application")) { success in
                if success { _isCompanionPresenting = true }
            }
        } else {
            _isCompanionPresenting = true
        }
    }

	@ViewBuilder
	private func _resignSection() -> some View {
		if app.isSigned {
			NBSection(.localized("Re-sign")) {
				Button {
					_resignWithLastSettings()
				} label: {
					Label(
						.localized(SigningProfileStore.shared.profile(forBundleID: app.identifier) != nil
							? "Re-sign with last settings"
							: "Sign again"),
						systemImage: "signature"
					)
				}
                .disabled(_isResigning)
			} footer: {
				Text(.localized("Signs this app again with the tweaks, entitlements and certificate it used before. Install it again afterwards, or export it."))
			}
		}
	}

	private func _resignWithLastSettings() {
		guard AutoSignManager.canSign else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Auto sign needs a certificate. Import one in Settings → Certificates.")
			)
			return
		}

        let profile = SigningProfileStore.shared.profile(forBundleID: app.identifier)
        let certificate = SigningProfileStore.shared.certificate(for: profile)
        let options = (profile?.options ?? Options.batchBase).resolved(for: app)
        let checks = PreflightChecks.run(app: app, options: options, certificate: certificate)
        var lines = [String.localized("Bundle identifier: %@", arguments: options.appIdentifier ?? app.identifier ?? .localized("Unknown"))]
        if let saved = profile?.savedAt { lines.append(saved.formatted()) }
        if let expiry = certificate?.expiration {
            lines.append(String.localized("Certificate expiry: %@", arguments: expiry.formatted()))
        }
        if let expected = profile?.certificateUUID, expected != certificate?.uuid {
            lines.append(.localized("The saved certificate is unavailable. The current selection would be used instead."))
        }
        lines.append(contentsOf: checks.issues.map { LogRedaction.redact($0.title + ": " + $0.detail) })
        lines.append(contentsOf: OneShotTweakFiles.replayNotices(for: profile?.oneShotFileNames ?? []))
        lines.append(.localized("Saved settings are reused, but source contents are not fingerprinted. Review options if the app has changed."))
        // Built from the rule the run follows, so the review cannot promise one thing while the
        // run does another. It used to say the copy is replaced; whether it is now depends on
        // Auto Cleanup's "Delete Signed App".
        lines.append(PostSignArtifacts.repeatSigningNotice(settings: .stored()))
        // "Sign Anyway" is only offered when the review above listed blocking issues that may
        // be accepted, and choosing it is the user accepting them. The run has to be told: without this it stayed
        // in strict mode and stopped on the issue that had just been confirmed.
        let overridesBlockingIssues = checks.canSignAnyway
        // Requirements iOS enforces at install leave nothing to confirm: the run would be
        // refused before it started, so the review offers no action that starts it.
        guard !checks.hasMandatoryFailure else {
            lines.append(.localized("This app cannot be signed with the saved certificate and profile. Open Sign to change them."))
            UIAlertController.showAlertWithOk(
                title: .localized("Review repeat signing"), message: lines.joined(separator: "\n"))
            return
        }
        UIAlertController.showAlertWithOptions(
            title: .localized("Review repeat signing"), message: lines.joined(separator: "\n"),
            actions: [
                (.localized("Cancel"), .cancel, nil),
                (checks.canSignAnyway ? .localized("Sign Anyway") : .localized("Sign Again"), checks.canSignAnyway ? .destructive : .default, {
                    guard !_isResigning else { return }
                    _isResigning = true
                    Task {
                        defer { _isResigning = false }
                        switch await AutoSignManager.shared.sign(app, overridingBlockingIssues: overridesBlockingIssues) {
                        case .success: Toast.success(.localized("Signed successfully"), systemImage: "checkmark.seal.fill")
                        case .failure(let error): Toast.error(LogRedaction.redact(error.localizedDescription), duration: .sticky)
                        }
                    }
                })
            ]
        )
	}

	/// Duplicate this app under a new name and bundle ID.
	@ViewBuilder
	private func _cloneSection() -> some View {
		NBSection(.localized("Clone")) {
			Button {
				_isClonePresenting = true
			} label: {
				Label(.localized("Clone App"), systemImage: "doc.on.doc")
			}
		} footer: {
			Text(.localized("Creates a second copy with its own name and bundle identifier, so both can be installed side by side."))
		}
	}

	/// Newer public version on the App Store, when tracking is enabled and the
	/// bundle ID is listed there.
	@ViewBuilder
	private func _appStoreSection() -> some View {
		if let info = _appStoreTracker.info(for: app.identifier) {
			NBSection(.localized("App Store")) {
				LabeledContent(.localized("Latest Version"), value: info.version)

				if let date = info.releaseDate {
					LabeledContent(.localized("Released"), value: date.formatted(date: .abbreviated, time: .omitted))
				}

				if _appStoreTracker.hasNewerVersion(than: app) {
					Text(.localized("A newer version is available on the App Store."))
						.font(.footnote)
						.foregroundStyle(.orange)
				}

				if let storeURL = info.storeURL, let url = URL(string: storeURL) {
					Button {
						UIApplication.shared.open(url)
					} label: {
						Label(.localized("Open in App Store"), systemImage: "arrow.up.forward.app")
					}
				}
			}
		}
	}

	@ViewBuilder
	private func _infoSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Info")) {
			if let name = app.name {
				_infoCell(.localized("Name"), desc: name)
			}

			if let ver = app.version {
				_infoCell(.localized("Version"), desc: ver)
			}

			if let id = app.identifier {
				_infoCell(.localized("Identifier"), desc: id)
			}

			if let originalId = app.originalIdentifier, originalId != app.identifier {
				_infoCell(.localized("Original Identifier"), desc: originalId)
			}

			NavigationLink {
				SigningDescriptionView(
					title: .localized("Description"),
					initialValue: LinkTagParser.strip(from: _displayedDescription) ?? "",
					onSave: { newValue in
						var saved = newValue
						if let tags = LinkTagParser.rawTags(in: _displayedDescription) {
							saved = saved.map { $0 + tags } ?? tags
						}
						Storage.shared.updateDescription(for: app, description: saved)
						_displayedDescription = saved
					}
				)
			} label: {
				LabeledContent(.localized("Description")) {
					Text(verbatim: LinkTagParser.strip(from: _displayedDescription) ?? String.localized("None"))
						.lineLimit(1)
				}
			}
			.copyableText(LinkTagParser.strip(from: _displayedDescription) ?? "")

			if let date = app.date {
				_infoCell(.localized("Date Added"), desc: date.formatted())
			}
		}
	}
	
	/// What the device and the stored signature actually say.
	///
	/// This is the sheet where a user asks "why is this not updating?" — so it shows the
	/// certificate the bundle carries, its expiry, and whether it is the certificate the library
	/// entry points at.
	@ViewBuilder
	private func _signatureSection(for app: AppInfoPresentable) -> some View {
		let status = _status.status(for: app)
		let rows = status.signatureRows(certificateRow: _certificateMatchRow(for: app, status: status))

		if app.isSigned, !rows.isEmpty {
			NBSection(.localized("Signature")) {
				ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
					_infoCell(row.title, desc: row.value)
				}
			}
		}
	}

	/// Whether the certificate on the entry is the one the bundle carries, in one sentence.
	private func _certificateMatchRow(for app: AppInfoPresentable, status: LibraryAppStatus) -> String? {
		guard
			let certificate = Storage.shared.getCertificate(from: app),
			let signature = status.signature
		else {
			return nil
		}

		return CertificateIdentity.match(state: signature, certificate: certificate).summary
	}

	@ViewBuilder
	private func _certSection(for app: AppInfoPresentable) -> some View {
		if let cert = Storage.shared.getCertificate(from: app) {
			NBSection(.localized("Certificate")) {
				CertificatesCellView(
					cert: cert
				)
			}
		}
	}
	
	@ViewBuilder
	private func _bundleSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Bundle")) {
			NavigationLink(.localized("Browse Files")) {
				IPALibraryExplorerView(app: app, embedded: true)
			}
			NavigationLink(.localized("Alternative Icons")) {
				SigningAlternativeIconView(app: app, appIcon: .constant(nil), isModifing: false)
			}
			NavigationLink(.localized("Frameworks & PlugIns")) {
				SigningFrameworksView(app: app, options: .constant(nil))
			}
		}
	}
	
	@ViewBuilder
	private func _executableSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Executable")) {
			NavigationLink(.localized("Dylibs")) {
				SigningDylibView(app: app, options: .constant(nil))
			}
		}
	}
	
	@ViewBuilder
	private func _linksSection(for app: AppInfoPresentable) -> some View {
		ForEach(LinkTagParser.links(in: _displayedDescription)) { link in
			Button {
				link.tag.open(link.url)
			} label: {
				Label {
					Text(link.tag.title)
				} icon: {
					Image(systemName: link.tag.symbol)
				}
			}
		}
	}

	@ViewBuilder
	private func _infoCell(_ title: String, desc: String) -> some View {
		LabeledContent(title) {
			Text(desc)
		}
		.copyableText(desc)
	}
}
