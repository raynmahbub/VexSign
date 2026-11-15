//
//  SigningView.swift
//  VexSign
//
//  Created by VexSign Contributors on 14.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

/// How long the signing sheet waits for the log sheet's dismissal callback before closing itself.
enum SigningCompletionHandOff {
	/// Longer than a sheet dismissal (about 0.35 s), so the normal callback always wins.
	static let fallbackDelay: TimeInterval = 0.8
}

private enum SigningSheet: String, Identifiable {
	case preflight
	case logs

	var id: String { rawValue }
}

/// Any option, selected identity or inventory change invalidates the visible approval
/// immediately, even before SwiftUI starts the replacement asynchronous inspection.
private struct SigningReadinessInput: Equatable {
    let options: Options
    let certificate: CertificateRecord?
    let inventory: [CertificateRecord]
    let refresh: UUID
    let prepared: Bool
}

// MARK: - View
struct SigningView: View {
    @EnvironmentObject var services: AppContainer
	@Environment(\.dismiss) var dismiss
	@State private var _temporaryOptions: Options = .defaultOptions
    @State private var _prepared = false
    let installAfterSigning: Bool
    let accountHandoff: AppleAccountSigningHandoff?
	@State private var _temporaryCertificate: Int
	@State private var _isSigning = false
    @State private var _signingRequestID: String?
    @State private var _currentStage: SigningStage?
    @State private var _reachedStages: Set<SigningStage> = []
    /// The run finished successfully. Distinct from `_postSignAction`, which only exists to hand
    /// off when the log sheet was open, and from verification, which the engine reports itself.
    @State private var _signingSucceeded = false
    /// Set only by the engine's own signature verification.
    @State private var _signatureVerified = false
    @State private var _signingError: String?
    @State private var _compatibilityRemovedComponents: [String] = []
    @State private var _readiness = SigningReadiness.checking(requiresIdentity: true)
    @State private var _readinessInput: SigningReadinessInput?
    @State private var _readinessRefresh = UUID()
    @Environment(\.scenePhase) private var _scenePhase
	@State private var _presentedSheet: SigningSheet?
    @State private var _reviewedAuthorization: SigningResolutionAuthorization?
	@State private var _signAfterReview = false
    /// Set when the user leaves the preflight sheet through "Sign Anyway".
    @State private var _signOverridingBlockingIssues = false
    @State private var _reviewedSetup: SigningPreflightSnapshot?
    @State private var _wasCancelled = false
    @Environment(\.accessibilityReduceMotion) private var _reduceMotion
	@State private var _postSignAction: (() -> Void)?
	@State var appIcon: UIImage?
	@AppStorage("VexSign.autoShowSigningLogs") private var _autoShowLogs: Bool = false
	/// The authoritative record of signing runs. Observed so the workflow shows the persisted
	/// execution trace for this app when nothing is running in this sheet.
	@EnvironmentObject private var _tasks: TaskWorkspaceModel

	// MARK: Fetch
	@WorkspaceQuery(\.certificates, order: .newestFirst) private var certificates: [CertificateRecord]
	
	private func _selectedCert() -> CertificateRecord? {
        if let accountHandoff {
            guard accountHandoff.matches(app) else { return nil }
            return accountHandoff.certificate(in: certificates)
        }
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}


	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable, installAfterSigning: Bool = false, accountHandoff: AppleAccountSigningHandoff? = nil) {
		self.app = app
        self.installAfterSigning = installAfterSigning
        self.accountHandoff = accountHandoff
		let storedCert = UserDefaults.standard.integer(forKey: "vexsign.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	/// What the certificate picker compares against: the app as the current options will leave it.
	private var _compatibilityTarget: ProfileCompatibility.Target {
        services.signing.compatibilityTarget(app: app, options: _temporaryOptions)
	}

	/// What the Signing workflow panel shows.
	///
	/// A live run wins: its stages are being reported right now. With nothing live, the panel is
	/// rebuilt from the persisted execution trace of this app's newest signing task instead of
	/// starting from an empty set — which is why an app that was signed by "Sign & Install",
	/// Update All or a batch job no longer reports every step as "Not run".
	private var _workflowSnapshot: SigningWorkflowSnapshot {
		let hasLiveRun = _isSigning || !_reachedStages.isEmpty || _signingSucceeded
			|| _signatureVerified || _signingError != nil || _wasCancelled
		if hasLiveRun {
			return SigningWorkflowSnapshot(
				reached: _reachedStages,
				current: _currentStage,
				running: _isSigning,
				succeeded: _signingSucceeded,
				verified: _signatureVerified,
				failed: _signingError != nil,
				cancelled: _wasCancelled
			)
		}
		guard let trace = _tasks.signingTrace(subjectID: app.uuid) else { return SigningWorkflowSnapshot() }
		return SigningWorkflowSnapshot(trace: trace)
	}

    private func _resolvedOptions(_ base: Options) -> Options {
        var options = services.signing.resolve(base, for: app)
        if accountHandoff != nil {
            options.signingOption = .default
            options.automaticallyResolveSigningIdentity = false
        }
        return options
    }

    private var _accountHandoffIsCurrent: Bool {
        accountHandoff == nil || (_selectedCert() != nil
            && _temporaryOptions.signingOption == .default
            && _temporaryOptions.automaticallyResolveSigningIdentity == false)
    }

    private var _inspectionInput: SigningReadinessInput {
        .init(options: _temporaryOptions, certificate: _selectedCert(), inventory: certificates,
              refresh: _readinessRefresh, prepared: _prepared)
    }

    private var _currentReadiness: SigningReadiness {
        guard _isSigning || _readinessInput == _inspectionInput else {
            return .checking(requiresIdentity: _temporaryOptions.signingOption == .default)
        }
        return _readiness
    }

    /// Show the actual app/profile requirement, not only a generic failure title.
    private var _readinessDetail: String? {
        let readiness = _currentReadiness
        if let failure = readiness.auditFailure { return failure }
        if let issue = readiness.preflight.issues.first(where: \.isMandatory) {
            return [issue.detail, issue.remediation].compactMap { $0 }.joined(separator: "\n")
        }
        if let finding = readiness.evidence?.report.blocking.first { return finding.detail }
        if let component = readiness.resolution?.components.first(where: { $0.status != .valid }) {
            return ([component.bundleIdentifier] + component.issues).joined(separator: "\n")
        }
        return nil
    }

    /// Identity and setup rows consume the same completed inspection as the action
    /// panel and review sheet. A selected row alone can no longer pass the first row.
    private var _checklistEvidence: SigningChecklistEvidence {
        let readiness = _currentReadiness
        let identity: SigningChecklistEvidence.Check
        if !readiness.requiresIdentity { identity = .notNeeded }
        else if readiness.isChecking || readiness.resolution == nil { identity = .notRun }
        else if readiness.identitiesValidated { identity = .passed }
        else { identity = .failed(_readinessDetail ?? .localized("Compatible identities and profiles are required for every retained component.")) }

        let preflight: SigningChecklistEvidence.Check
        switch readiness.state {
        case .checking: preflight = .notRun
        case .blocked: preflight = .failed(_readinessDetail ?? .localized("Signing inspection did not establish compatibility. Review the component requirements."))
        case .ready: preflight = .passed
        case .warning: preflight = .passedWithWarnings(readiness.warningCount)
        }
        return SigningChecklistEvidence(identity: identity, preflight: preflight, run: _workflowSnapshot)
    }

	// MARK: Body
    var body: some View {
		NBNavigationView(.localized("Signing"), displayMode: .inline) {
			ScrollViewReader { proxy in
                Form {
                    Section {
                        Label(_currentReadiness.state.title, systemImage: _currentReadiness.state.symbol)
                            .foregroundStyle(_currentReadiness.state.color)
                            .accessibilityIdentifier("signing.readiness.state")
                        if let detail = _readinessDetail, _currentReadiness.state == .blocked {
                            Text(LogRedaction.redact(detail)).font(.footnote).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(.localized("Original Bundle Identifiers are preserved. Import compatible profiles and their matching identities; changing an identifier is not a provisioning fix."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(.localized("Check Again")) { _readinessRefresh = UUID() }
                            .disabled(_currentReadiness.isChecking)
                            .accessibilityIdentifier("signing.readiness.refresh")
                        SigningChecklistView(evidence: _checklistEvidence)
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
						appIcon: $appIcon
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
							services.installation.enqueue(app)
						} label: {
							Label(.localized("Install Without Signing"), systemImage: "bolt.badge.checkmark")
						}

						Divider()

						Button(.localized("Reset")) {
							_temporaryOptions = services.signingPreferences.options
							_temporaryOptions = services.signing.reset(_temporaryOptions, for: app)
							appIcon = nil
						}
						if !services.signingPreferences.profiles.isEmpty {
							Section(.localized("Apply Profile")) {
								ForEach(services.signingPreferences.profiles) { profile in
									Button(profile.name) {
										_temporaryOptions = _resolvedOptions(profile.options)
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
							services.signingPreferences.save(NamedSigningProfile(
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
                    let current = services.signing.preflight(app: app, options: _temporaryOptions, certificate: _selectedCert())
                    guard _currentReadiness.canApprove,
                          _reviewedAuthorization == _currentReadiness.resolution?.authorization,
                          _reviewedSetup?.matches(options: _temporaryOptions,
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
                            SigningPreflightReviewView(
                                app: app, options: $_temporaryOptions, certificate: _selectedCert(),
                                readiness: _currentReadiness,
                                reviewOptions: { _presentedSheet = nil },
                                refresh: { _readinessRefresh = UUID() },
                                sign: { overridingBlockingIssues, authorization in
                                    _approveReview(overridingBlockingIssues: overridingBlockingIssues,
                                                   authorization: authorization)
                                }
                            )
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
			.onAppear {
                guard !_prepared else { return }
                _prepared = true
                let base = LibraryAppWorkflowAction.signingOptions(from: services.signingPreferences.options, installAfterSigning: installAfterSigning)
                _temporaryOptions = _resolvedOptions(base)
            }
        .onChange(of: _temporaryOptions.automaticallyResolveSigningIdentity) { _, value in
            if accountHandoff != nil, value != false {
                _temporaryOptions.automaticallyResolveSigningIdentity = false
            }
        }
        .task(id: _inspectionInput) { [input = _inspectionInput] in
            await _inspectReadiness(input)
        }
        .onChange(of: _scenePhase) { _, phase in
            if phase == .active, !_isSigning { _readinessRefresh = UUID() }
        }
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
            if !_isSigning {
                Label(_currentReadiness.state.title, systemImage: _currentReadiness.state.symbol)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(_currentReadiness.state.color)
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
            .disabled(!_currentReadiness.canApprove)
            .accessibilityHint(Text(.localized("Requires a completed compatible component review. Signing never bypasses provisioning requirements.")))
            .accessibilityIdentifier(A11y.Signing.start)
            if !_currentReadiness.canApprove {
                Button { _start() } label: {
                    Label(.localized("Review Signing Issues"), systemImage: "checklist")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("signing.reviewIssues")
            }
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
            Toggle("Automatically find compatible identities", isOn: Binding(
                get: { _temporaryOptions.automaticallyResolveSigningIdentity != false },
                set: { _temporaryOptions.automaticallyResolveSigningIdentity = $0 }
            ))
            .disabled(accountHandoff != nil)
            Text("Automatic resolution checks every imported profile. The selected identity is a preference, not an authorization. Turn Automatic off to require that identity. Original Bundle Identifiers are preserved.")
                .font(.caption).foregroundStyle(.secondary)
            if accountHandoff != nil {
                if let cert = _selectedCert() {
                    CertificatesCellView(cert: cert, target: _compatibilityTarget)
                } else {
                    Label(.localized("The provisioned identity is unavailable or expired. Return to provisioning; another certificate will not be substituted."), systemImage: "exclamationmark.shield")
                }
            } else if let cert = _selectedCert() {
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
        if accountHandoff != nil {
            guard _accountHandoffIsCurrent else {
                _temporaryOptions.signingOption = .default
                _temporaryOptions.automaticallyResolveSigningIdentity = false
                _readinessRefresh = UUID()
                return
            }
        }
        NBHaptic.tap()
        _signAfterReview = false
        _signOverridingBlockingIssues = false
        _reviewedAuthorization = nil
        _reviewedSetup = nil
        _presentedSheet = .preflight
    }

    private func _approveReview(overridingBlockingIssues: Bool, authorization: SigningResolutionAuthorization?) {
        let readiness = _currentReadiness
        guard _accountHandoffIsCurrent, readiness.canApprove, authorization == readiness.resolution?.authorization else {
            Toast.info(.localized("Signing setup changed. Review it again before starting."))
            _readinessRefresh = UUID()
            return
        }
        _reviewedSetup = SigningPreflightSnapshot(options: _temporaryOptions,
            certificateUUID: _selectedCert()?.uuid, issues: readiness.preflight.issues)
        _reviewedAuthorization = authorization
        _signAfterReview = true
        _signOverridingBlockingIssues = overridingBlockingIssues
        _presentedSheet = nil
    }

    /// Cancellation and the input-key comparison prevent late results from an old
    /// identity/options inspection re-enabling approval for the current setup.
    @MainActor
    private func _inspectReadiness(_ input: SigningReadinessInput) async {
        guard input.prepared, !_isSigning else { return }
        _readinessInput = input
        _readiness = .checking(requiresIdentity: input.options.signingOption == .default)
        do { try await Task.sleep(for: .milliseconds(250)) }
        catch { return }
        guard !Task.isCancelled, input == _inspectionInput else { return }
        let preflight = services.signing.preflight(app: app, options: input.options, certificate: input.certificate)
        do {
            let evidence = try await services.signing.inspect(app: app, options: input.options, certificate: input.certificate)
            try Task.checkCancellation()
            guard input == _inspectionInput, !_isSigning else { return }
            _readiness = .init(requiresIdentity: input.options.signingOption == .default,
                preflight: preflight, evidence: evidence, auditFailure: nil)
        } catch {
            guard !Task.isCancelled, input == _inspectionInput, !_isSigning else { return }
            _readiness = .init(requiresIdentity: input.options.signingOption == .default,
                preflight: preflight, evidence: nil, auditFailure: LogRedaction.redact(error.localizedDescription))
        }
    }

	/// Stops the run in flight. The pipeline notices between stages (and inside the long bundle
	/// walk), removes everything it copied, and reports back as cancelled — so the sheet stays
	/// usable and nothing half-signed is left in the library.
	private func _stopSigning() {
		if let id = _signingRequestID { services.signing.cancel(id) }
	}

	private func _beginSign(overridingBlockingIssues: Bool = false) {
        guard !_isSigning else { return }
        guard _accountHandoffIsCurrent else {
            _readinessRefresh = UUID()
            Toast.info(.localized("Signing setup changed. Review it again before starting."))
            return
        }
        // Preserve the reviewed inputs through asynchronous completion/dismissal.
        let runOptions = _temporaryOptions
        let runCertificate = _selectedCert()
        UIApplication.shared.endEditing()
        _signingError = nil
        _compatibilityRemovedComponents = []
        _wasCancelled = false
        _signingSucceeded = false
        _signatureVerified = false
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

		services.signing.signPackage(
			app,
			using: runOptions,
			icon: appIcon,
			certificate: runCertificate,
			overridesBlockingPreflightIssues: overridingBlockingIssues,
            requestID: requestID,
            reviewedAuthorization: _reviewedAuthorization,
            onStage: { stage in
                let previousStep = _currentStage.map { SigningWorkspaceStep(stage: $0) }
                _currentStage = stage
                _reachedStages.insert(stage)
                if UIAccessibility.isVoiceOverRunning, previousStep != SigningWorkspaceStep(stage: stage) {
                    let announcement = NSAttributedString(string: stage.title, attributes: [.accessibilitySpeechQueueAnnouncement: true])
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            },
            onVerified: {
                // The engine's own verification accepted the bundle. This is what marks Verify
                // complete — not the run finishing, which can happen without verifying at all.
                _signatureVerified = true
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
                _readinessRefresh = UUID()

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
                _signingSucceeded = true
                if _compatibilityRemovedComponents.isEmpty {
                    // "Verified" is said only when the engine reported its own check passed.
                    Toast.success(
                        _signatureVerified
                            ? .localized("Signature verified and ready for installation")
                            : .localized("Signed successfully"),
                        systemImage: "checkmark.seal.fill"
                    )
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
				services.signing.capture(
					options: runOptions,
					certificate: runCertificate,
					for: app, requestID: requestID
				)

				// The run injected its own copies, so the files staged for this sheet are still
				// on disk. The sheet closes now and nothing else will read them. They are kept
				// after a failure on purpose: that is what lets the next attempt start.

                let automaticInstall = runOptions.post_installAppAfterSigned
                let finish: (SigningCompletionAction) -> Void = { intent in
					// The signed copy stays, whatever the settings are: it is what the sheet was
					// opened to make. "Delete Signed App" used to delete it right here whenever
					// the run was not set to install it.
					//
					// Only the copy the sheet was opened on can go: the sheet's own "Delete After
					// Signing" and Auto Cleanup's Delete Unsigned / Signed App decide, and
					// only once the signed copy is confirmed to be in the library. The storage
					// toggles are swept in the same call.
					services.signing.finish(
                        source: app, output: signed, options: runOptions, certificate: runCertificate,
                        deletesSource: runOptions.post_deleteAppAfterSigned, requestID: requestID
					)

                    if intent.shouldInstall(automaticInstall: automaticInstall) {
                        services.installation.enqueue(signed)
                    } else if intent == .share {
                        services.installation.enqueue(signed, exporting: true)
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
                    // The hand-off above runs from the log sheet's onDismiss. That callback is
                    // not guaranteed: when it is lost (the same loss `InstallQueue` guards against
                    // for its own card) nothing else closes this sheet, and a finished run sits
                    // open. Take the pending action after the dismissal animation if it is still
                    // there. Both paths take it and clear it, so it runs once.
                    DispatchQueue.main.asyncAfter(deadline: .now() + SigningCompletionHandOff.fallbackDelay) {
                        guard _presentedSheet == nil, let pending = _postSignAction else { return }
                        _postSignAction = nil
                        pending()
                    }
                } else {
                    finish(.done)
                }
			}
		}
	}
}
