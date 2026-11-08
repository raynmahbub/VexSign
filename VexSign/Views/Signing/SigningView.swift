//
//  SigningView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 14.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

private enum SigningSheet: String, Identifiable {
	case preflight
	case logs

	var id: String { rawValue }
}

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isSigning = false
    @State private var _signingRequestID: String?
    @State private var _currentStage: SigningStage?
    @State private var _reachedStages: Set<SigningStage> = []
    @State private var _signingError: String?
    @State private var _compatibilityRemovedComponents: [String] = []
	@State private var _preflightResult: PreflightResult?
	@State private var _presentedSheet: SigningSheet?
	@State private var _signAfterReview = false
    /// Set when the user leaves the preflight sheet through "Sign Anyway".
    @State private var _signOverridingBlockingIssues = false
    @State private var _reviewedSetup: SigningPreflightSnapshot?
    @State private var _wasCancelled = false
    @Environment(\.accessibilityReduceMotion) private var _reduceMotion
	@State private var _postSignAction: (() -> Void)?
	@State var appIcon: UIImage?
	@AppStorage("VexSign.autoShowSigningLogs") private var _autoShowLogs: Bool = false

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}

	private func _provisioningIdentifier() -> String? {
		guard
			let cert = _selectedCert(),
			let decoded = Storage.shared.getProvisionFileDecoded(for: cert),
			let appId = decoded.Entitlements?["application-identifier"]?.value as? String
		else {
			return nil
		}

		let bundleId = appId.drop { $0 != "." }.dropFirst()
		guard !bundleId.isEmpty, !bundleId.contains("*") else { return nil }
		return String(bundleId)
	}
	
	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable, installAfterSigning: Bool = false) {
		self.app = app
        __temporaryOptions = State(initialValue: LibraryAppWorkflowAction.signingOptions(
            from: OptionsManager.shared.options, installAfterSigning: installAfterSigning))
		let storedCert = UserDefaults.standard.integer(forKey: "vexsign.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	/// What the certificate picker compares against: the app as the current options will leave it.
	private var _compatibilityTarget: ProfileCompatibility.Target {
		let bundle = Storage.shared.getAppDirectory(for: app)
		let nested = bundle.map {
			NestedBundleAudit.requiredIdentifiers(in: $0, removeAppExtensions: _temporaryOptions.removeAppExtensions)
		} ?? []
		let removableExtensions = bundle.map {
			NestedBundleAudit.removableExtensionIdentifiers(in: $0, removeAppExtensions: _temporaryOptions.removeAppExtensions)
		} ?? []
		return ProfileCompatibility.Target(
			app: app,
			options: _temporaryOptions,
			nestedBundleIdentifiers: nested,
			removableExtensionIdentifiers: removableExtensions
		)
	}

	// MARK: Body
    var body: some View {
		NBNavigationView(.localized("Signing"), displayMode: .inline) {
			ScrollViewReader { proxy in
                Form {
                    Section {
                        SigningWorkflowView(
                            reached: _reachedStages, current: _currentStage,
                            running: _isSigning, succeeded: _postSignAction != nil,
                            failed: _signingError != nil, cancelled: _wasCancelled
                        )
                    }
                    if let error = _signingError {
                        Section {
                            Label(.localized("Signing failed"), systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text(error).font(.caption.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(.localized("Review the error and logs, adjust your options, then try again."))
                                .foregroundStyle(.secondary)
                        }
                    }
					SigningCustomizationView(
						app: app,
						options: $_temporaryOptions,
						appIcon: $appIcon,
						identifierSuggestion: _provisioningIdentifier()
					)
					_cert()
					SigningAdvancedView(
						app: app,
						options: $_temporaryOptions,
						certificate: _selectedCert(),
						scrollProxy: proxy
					)
				}
                .scrollContentBackground(.hidden)
                .background(Theme.background)
			}
			.disabled(_isSigning)
            .animation(_reduceMotion ? nil : .easeInOut(duration: 0.18), value: _isSigning)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                signingActionPanel
            }

			.toolbar {
                NBToolbarButton(role: .dismiss)

				ToolbarItemGroup(placement: .topBarTrailing) {
					Menu {
						Button {
							dismiss()
							InstallQueue.shared.enqueue(app)
						} label: {
							Label(.localized("Install Without Signing"), systemImage: "bolt.badge.checkmark")
						}

						Divider()

						Button(.localized("Reset")) {
							_temporaryOptions = OptionsManager.shared.options
							_temporaryOptions.resetPerApp(for: app)
							appIcon = nil
						}
						if !NamedSigningProfileStore.shared.profiles.isEmpty {
							Section(.localized("Apply Profile")) {
								ForEach(NamedSigningProfileStore.shared.profiles) { profile in
									Button(profile.name) {
										_temporaryOptions = profile.options.resolved(for: app)
										if let uuid = profile.certificateUUID,
										   let index = certificates.firstIndex(where: { $0.uuid == uuid }) {
											_temporaryCertificate = index
										}
									}
								}
							}
						}
						Button(.localized("Save as Named Profile")) {
							let name = app.name ?? .localized("Profile")
							NamedSigningProfileStore.shared.save(NamedSigningProfile(
								name: name,
								options: _temporaryOptions,
								certificateUUID: _selectedCert()?.uuid
							))
							Toast.success(.localized("Saved profile"), systemImage: "person.crop.rectangle.stack")
						}
					} label: {
						Image(systemName: "ellipsis.circle")
					}
                    .disabled(_isSigning)
				}
				}
		}
            // Preflight and logs share one presentation slot. Attach the presentation to the
            // SigningView root rather than a child of its NavigationStack so it remains reliable
            // when this screen is itself presented by Home or Library.
            .sheet(item: $_presentedSheet, onDismiss: {
                let action = _postSignAction
                _postSignAction = nil
                action?()

                if _signAfterReview {
                    _signAfterReview = false
                    let current = PreflightChecks.run(app: app, options: _temporaryOptions, certificate: _selectedCert())
                    guard _reviewedSetup?.matches(options: _temporaryOptions,
                        certificateUUID: _selectedCert()?.uuid, issues: current.issues) == true else {
                        Toast.info(.localized("Signing setup changed. Review it again before starting."))
                        return
                    }
                    _beginSign(overridingBlockingIssues: _signOverridingBlockingIssues)
                }
            }) { sheet in
                NavigationStack {
                    Group {
                        switch sheet {
                        case .preflight:
                            Group {
                                if let result = _preflightResult {
                                    SigningPreflightReviewView(
                                        app: app, options: _temporaryOptions, certificate: _selectedCert(), result: result,
                                        reviewOptions: { _presentedSheet = nil },
                                        sign: { overridingBlockingIssues in
                                            _signAfterReview = true
                                            _signOverridingBlockingIssues = overridingBlockingIssues
                                            _presentedSheet = nil
                                        }
                                    )
                                } else {
                                    VStack(spacing: 16) {
                                        ProgressView()
                                        Text(.localized("Preparing signing review…"))
                                        Button(.localized("Close")) { _presentedSheet = nil }
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .navigationTitle(.localized("Ready to Sign"))
                                    .navigationBarTitleDisplayMode(.inline)
                                }
                            }
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                        case .logs:
                            SigningLogView()
                                .accessibilityIdentifier(A11y.Signing.console)
                                .presentationDetents([.medium, .large])
                                .presentationDragIndicator(.visible)
                        }
                    }
                }
                .background(Theme.background.ignoresSafeArea())
			}
			.onAppear { _temporaryOptions = _temporaryOptions.resolved(for: app) }
        .interactiveDismissDisabled(_isSigning)
        .onDisappear { UIApplication.shared.endEditing() }
    }
}

// MARK: - Extension: View
extension SigningView {
    private var signingActionPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if _isSigning {
                HStack(spacing: Theme.Spacing.medium) {
                    ProgressView().accessibilityIdentifier(A11y.Signing.progress)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        Text(_currentStage?.title ?? .localized("Preparing signing request"))
                            .font(.headline)
                        Text(_temporaryOptions.post_installAppAfterSigned
                             ? .localized("After signing succeeds, iOS will ask to install this app.")
                             : .localized("Signing is separate from installation."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if _signingError != nil {
                Label(.localized("Signing failed. Review the details above or open logs."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            } else if _wasCancelled {
                Label(.localized("Signing cancelled"), systemImage: "stop.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            WorkspaceActionGroup { signingPanelButtons }
        }
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var signingPanelButtons: some View {
        if _isSigning {
            Button(role: .destructive) { _stopSigning() } label: {
                Label(.localized("Stop Signing"), systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(A11y.Signing.stop)
        } else {
            Button { _start() } label: {
                Label(.localized("Start Signing"), systemImage: "signature")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(A11y.Signing.start)
        }
        if _isSigning || _signingError != nil || _wasCancelled {
            Button { _presentedSheet = .logs } label: {
                Label(.localized("Show Logs"), systemImage: "text.alignleft")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate, target: _compatibilityTarget)
				} label: {
					CertificatesCellView(
						cert: cert,
						target: _compatibilityTarget
					)
				}
            } else {
                NavigationLink {
                    CertificatesView(selectedCert: $_temporaryCertificate, target: _compatibilityTarget)
                } label: {
                    Label(.localized("Choose Certificate"), systemImage: "checkmark.seal")
                }
            }
		}
	}
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start() {
		guard
			_selectedCert() != nil || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		NBHaptic.tap()

		// Preflight: catch bundle id, plist, dylib and certificate problems before the long sign.
		let preflight = PreflightChecks.run(
			app: app,
			options: _temporaryOptions,
			certificate: _selectedCert()
		)
        _signOverridingBlockingIssues = false
        _preflightResult = preflight
        _reviewedSetup = SigningPreflightSnapshot(options: _temporaryOptions,
            certificateUUID: _selectedCert()?.uuid, issues: preflight.issues)
		_presentedSheet = .preflight
	}

	/// Stops the run in flight. The pipeline notices between stages (and inside the long bundle
	/// walk), removes everything it copied, and reports back as cancelled — so the sheet stays
	/// usable and nothing half-signed is left in the library.
	private func _stopSigning() {
		if let id = _signingRequestID { SigningService.shared.cancel(id) }
	}

	private func _beginSign(overridingBlockingIssues: Bool = false) {
        guard !_isSigning else { return }
        UIApplication.shared.endEditing()
        _signingError = nil
        _compatibilityRemovedComponents = []
        _wasCancelled = false
        _currentStage = nil
        _reachedStages = []
        let requestID = UUID().uuidString
        _signingRequestID = requestID
        _isSigning = true
		if _autoShowLogs {
            // A preflight sheet may have just finished dismissing. Present logs after that
            // transition completes instead of replacing its item mid-dismissal (which can leave
            // only the system's blurred presentation backdrop visible on iOS).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard _isSigning, _signingRequestID == requestID else { return }
                _presentedSheet = .logs
            }
        }

		FR.signPackageFile(
			app,
			using: _temporaryOptions,
			icon: appIcon,
			certificate: _selectedCert(),
			overridesBlockingPreflightIssues: overridingBlockingIssues,
            requestID: requestID,
            onStage: { stage in
                let previousStep = _currentStage.map { SigningWorkspaceStep(stage: $0) }
                _currentStage = stage
                _reachedStages.insert(stage)
                if UIAccessibility.isVoiceOverRunning, previousStep != SigningWorkspaceStep(stage: stage) {
                    let announcement = NSAttributedString(string: stage.title, attributes: [.accessibilitySpeechQueueAnnouncement: true])
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            },
            onCompatibilityRemoved: { components in
                _compatibilityRemovedComponents.append(contentsOf: components)
            }
        ) { result in
            guard _signingRequestID == requestID else { return }
            _signingRequestID = nil
            switch result {
			case .failure(let error):
				// Keep the sheet open so the user can fix and retry.
				_isSigning = false

				if error is CancellationError {
					// Stopping on purpose is not a failure, and the run has already cleaned up
					// after itself — say so quietly instead of showing an error the user caused.
                    _wasCancelled = true
					Toast.info(.localized("Signing cancelled"), systemImage: "stop.circle")
				} else {
                    let message = LogRedaction.redact(error.localizedDescription)
                    _signingError = message
                    Toast.error(message, duration: .sticky)
				}
			case .success(let signed):
				_isSigning = false
                if _compatibilityRemovedComponents.isEmpty {
                    Toast.success(.localized("Signed successfully"), systemImage: "checkmark.seal.fill")
                } else {
                    let components = _compatibilityRemovedComponents.joined(separator: ", ")
                    Toast.success(
                        .localized("Signed successfully. Compatibility mode skipped: %@.", arguments: components),
                        systemImage: "checkmark.seal.fill",
                        duration: .long
                    )
                }

				// Remember the exact settings + certificate so "Re-sign with last settings"
				// and Update All can reproduce this identity later.
				SigningProfileStore.shared.capture(
					options: _temporaryOptions,
					certificate: _selectedCert(),
					for: app
				)

                let automaticInstall = _temporaryOptions.post_installAppAfterSigned
                let finish: (SigningCompletionAction) -> Void = { intent in
					let deletesSource = _temporaryOptions.post_deleteAppAfterSigned && !app.isSigned

					if deletesSource {
						Storage.shared.deleteApp(for: app)
					}

					// Auto cleanup: honours Delete Unsigned / Signed App and the storage toggles.
					// Runs after the deletion above so it never reads a removed object.
					let remainingSource: AppInfoPresentable? = deletesSource ? nil : app
					CleanupManager.shared.runAfterSign(
						source: remainingSource,
						signed: signed,
						keepsSignedApp: intent.keepsSignedApp(automaticInstall: automaticInstall)
					)

                    if intent.shouldInstall(automaticInstall: automaticInstall) {
                        InstallQueue.shared.enqueue(signed)
                    } else if intent == .share {
                        InstallQueue.shared.enqueue(signed, exporting: true)
                    } else if intent == .library {
                        TabBarPreferences.shared.setHidden(.library, false)
                        TabSelectionObserver.shared.librarySection = .signedApps
                        TabSelectionObserver.shared.selectedTab = .library
                    }

					dismiss()
				}

                // Close the signing sheet as soon as signing succeeds. If the log sheet is
                // visible, dismiss it programmatically first; its onDismiss callback then hands
                // off and closes the signing sheet. Leaving the logs visible here used to make
                // successful runs look like the signing popup had stalled indefinitely.
                if _presentedSheet == .logs {
                    _postSignAction = { finish(.done) }
                    _presentedSheet = nil
                } else {
                    finish(.done)
                }
			}
		}
	}
}
