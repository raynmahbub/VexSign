//
//  SigningView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 14.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isSigning = false
    @State private var _currentStage: SigningStage?
    @State private var _reachedStages: Set<SigningStage> = []
    @State private var _signingError: String?
    @State private var _preflightResult: PreflightResult?
    @State private var _showPreflight = false
    @State private var _signAfterReview = false
    @State private var _reviewedSetup: SigningPreflightSnapshot?
    @State private var _didSign = false
    @State private var _wasCancelled = false
    @State private var _completionAction: ((SigningCompletionAction) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var _reduceMotion
	@State private var _isLogPresenting = false
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
	
	init(app: AppInfoPresentable) {
		self.app = app
		let storedCert = UserDefaults.standard.integer(forKey: "vexsign.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	/// What the certificate picker compares against: the app as the current options will leave it.
	private var _compatibilityTarget: ProfileCompatibility.Target {
		let nested = Storage.shared.getAppDirectory(for: app)
			.map {
				NestedBundleAudit.requiredIdentifiers(
					in: $0,
					removeAppExtensions: _temporaryOptions.removeAppExtensions
				)
			} ?? []
		return ProfileCompatibility.Target(
			app: app,
			options: _temporaryOptions,
			nestedBundleIdentifiers: nested
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
                            running: _isSigning, succeeded: _didSign || _postSignAction != nil,
                            failed: _signingError != nil, cancelled: _wasCancelled
                        )
                    }
                    if _didSign {
                        Section {
                            Label(.localized("Signing complete"), systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.title2.weight(.semibold))
                            Text(.localized("The signing pipeline completed. This does not confirm installation on your device."))
                                .foregroundStyle(.secondary)
                            Text(.localized("Install, share the IPA or view the signed copy in Library. Done applies your existing cleanup preferences."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
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
                if _didSign {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(.localized("Done")) { _finishCompletion() }
                    }
                } else {
                    NBToolbarButton(role: .dismiss)
                }

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
                    .disabled(_isSigning || _didSign)
				}
			}
            .sheet(isPresented: $_showPreflight, onDismiss: {
                if _signAfterReview {
                    _signAfterReview = false
                    let current = PreflightChecks.run(app: app, options: _temporaryOptions, certificate: _selectedCert())
                    guard _reviewedSetup?.matches(options: _temporaryOptions,
                        certificateUUID: _selectedCert()?.uuid, issues: current.issues) == true else {
                        Toast.info(.localized("Signing setup changed. Review it again before starting."))
                        return
                    }
                    _beginSign()
                }
            }) {
                if let result = _preflightResult {
                    SigningPreflightReviewView(
                        app: app, options: _temporaryOptions, certificate: _selectedCert(), result: result,
                        reviewOptions: { _showPreflight = false },
                        sign: {
                            _signAfterReview = true
                            _showPreflight = false
                        }
                    )
                }
            }
			.sheet(isPresented: $_isLogPresenting, onDismiss: {
                let action = _postSignAction
                _postSignAction = nil
                action?()
			}) {
				SigningLogView()
				.accessibilityIdentifier(A11y.Signing.console)
					.presentationDetents([.medium, .large])
					.presentationDragIndicator(.visible)
			}
		}
		.onAppear { _temporaryOptions = _temporaryOptions.resolved(for: app) }
        .interactiveDismissDisabled(_isSigning || _didSign)
        .onDisappear {
            UIApplication.shared.endEditing()
            // Preserve cleanup if the parent removes this workspace after success.
            if _completionAction != nil { _finishCompletion() }
        }
    }
}

// MARK: - Extension: View
extension SigningView {
    private func _finishCompletion(_ intent: SigningCompletionAction = .done) {
        let action = _completionAction
        _completionAction = nil
        action?(intent)
    }

    private var signingActionPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if _isSigning {
                HStack(spacing: Theme.Spacing.medium) {
                    ProgressView().accessibilityIdentifier(A11y.Signing.progress)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        Text(_currentStage?.title ?? .localized("Preparing signing request"))
                            .font(.headline)
                        Text(.localized("Signing is separate from installation."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if _didSign {
                Label(.localized("Signing complete — installation not confirmed"), systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
            } else if _signingError != nil {
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
        if _didSign {
            Button { _finishCompletion(.install) } label: {
                Label(.localized("Install"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            Menu {
                Button { _finishCompletion(.share) } label: {
                    Label(.localized("Share IPA"), systemImage: "square.and.arrow.up")
                }
                Button { _finishCompletion(.library) } label: {
                    Label(.localized("View in Library"), systemImage: "books.vertical")
                }
                Button(.localized("Done")) { _finishCompletion() }
            } label: {
                Label(.localized("More"), systemImage: "ellipsis.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        } else if _isSigning {
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
        if _isSigning || _signingError != nil || _didSign || _wasCancelled {
            Button { _isLogPresenting = true } label: {
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
        _preflightResult = preflight
        _reviewedSetup = SigningPreflightSnapshot(options: _temporaryOptions,
            certificateUUID: _selectedCert()?.uuid, issues: preflight.issues)
        _showPreflight = true
	}

	/// Stops the run in flight. The pipeline notices between stages (and inside the long bundle
	/// walk), removes everything it copied, and reports back as cancelled — so the sheet stays
	/// usable and nothing half-signed is left in the library.
	private func _stopSigning() {
		SigningService.shared.cancelAll()
	}

	private func _beginSign() {
        guard !_isSigning && !_didSign else { return }
        UIApplication.shared.endEditing()
        _signingError = nil
        _wasCancelled = false
        _currentStage = nil
        _reachedStages = []
		_isSigning = true
		if _autoShowLogs { _isLogPresenting = true }

		FR.signPackageFile(
			app,
			using: _temporaryOptions,
			icon: appIcon,
			certificate: _selectedCert(),
            onStage: { stage in
                let previousStep = _currentStage.map { SigningWorkspaceStep(stage: $0) }
                _currentStage = stage
                _reachedStages.insert(stage)
                if UIAccessibility.isVoiceOverRunning, previousStep != SigningWorkspaceStep(stage: stage) {
                    let announcement = NSAttributedString(string: stage.title, attributes: [.accessibilitySpeechQueueAnnouncement: true])
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            }
		) { result in
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
				Toast.success(.localized("Signed successfully"), systemImage: "checkmark.seal.fill")

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
                        TabSelectionObserver.shared.selectedTab = .library
                    }

					dismiss()
				}

                // Automatic install keeps its existing immediate (or log-deferred) handoff.
                // Manual signing gets an explicit outcome before applying cleanup on Done.
                if !_temporaryOptions.post_installAppAfterSigned {
                    _completionAction = finish
                    _didSign = true
                } else if _isLogPresenting {
					_postSignAction = { finish(.done) }
				} else {
                    finish(.done)
				}
			}
		}
	}
}
