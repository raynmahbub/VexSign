//
//  ProvisioningFlowView+Steps.swift
//  VexSign
//
//  The five steps of the provisioning wizard, separated from the flow that drives them.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

extension ProvisioningFlowView {
    // MARK: - Progress Header

    var provisioningProgressHeader: some View {
        VStack(spacing: 8) {
            HStack {
                ForEach(ProvisioningStep.allCases, id: \.self) { s in
                    Circle()
                        .fill(s.order <= step.order ? Color.accentColor : Color(uiColor: .quaternaryLabel))
                        .frame(width: 10, height: 10)
                    if s != .complete {
                        Rectangle()
                            .fill(s.order < step.order ? Color.accentColor : Color(uiColor: .quaternaryLabel))
                            .frame(height: 2)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Text(step.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - Step 1: Select App

    var selectAppStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "app.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text(.localized("Select an App to Provision"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(.localized("Choose an imported or signed app from your library. The app's bundle identifier will be registered with Apple."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let app = selectedApp {
                AppSelectionCard(app: app) {
                    selectedApp = nil
                }
            }

            Button {
                showAppPicker = true
            } label: {
                Label(selectedApp == nil ? .localized("Choose App") : .localized("Change App"), systemImage: "chevron.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProvisioning)

            if selectedApp != nil {
                Button(.localized("Next: Select Device")) {
                    step = .selectDevice
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Step 2: Select Device

    var selectDeviceStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text(.localized("Select Target Device"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(.localized("Enter the UDID of the device where the app will be installed. The device must be registered with your Apple Developer account."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text(.localized("Device UDID"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack {
                    TextField(.localized("00008030-001234567890ABCDEF"), text: $deviceIdentifier)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color(uiColor: .tertiarySystemFill))
                        .cornerRadius(10)

                    Button {
                        showDevicePicker = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityLabel(Text(.localized("Choose a device")))
                }
            }

            if !deviceIdentifier.isEmpty {
                Button(.localized("Next: Review")) {
                    guard let contextID else { return }
                    reviewedContextID = contextID
                    step = .review
                }
                .buttonStyle(.borderedProminent)
                .disabled(contextID == nil || provisioningTask != nil)
            }

            Button(.localized("Back")) {
                step = .selectApp
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Step 3: Review

    var reviewStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text(.localized("Review & Provision"))
                .font(.title2.weight(.semibold))

            Text(.localized("Review the provisioning plan before submitting to Apple. This will register the device, create an App ID, generate a certificate, and create a provisioning profile."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ReviewCard(
                appName: selectedApp?.name ?? .localized("Unknown"),
                bundleIdentifier: selectedApp?.identifier ?? .localized("Unknown"),
                deviceUDID: deviceIdentifier
            )

            if refreshReview {
                VStack(alignment: .leading, spacing: 8) {
                    Text(.localized("This runs six attended stages: provision, import the exact identity, re-sign the retained copy, hand it to your chosen delivery route, then verify. Each approval below still applies; nothing starts without it."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(.localized("Request one regeneration of the app’s existing Apple profile"), isOn: $consent.regeneration)
                    Toggle(.localized("I consent to exporting the renewed private key once for this refresh"), isOn: $consent.keyExport)
                }
            }

            if selectedApp?.isSigned == true && !refreshReview {
                Toggle(.localized("Require a later expiry than this signed library copy"), isOn: $consent.laterProfile)
                    .disabled(cellularReview)
                    .onChange(of: consent.laterProfile) { _, _ in consent.regeneration = false }
                if consent.laterProfile {
                    Toggle(.localized("Request one regeneration of this app’s existing Apple profile"), isOn: $consent.regeneration)
                    Text(.localized("Changes the profile on Apple’s portal. Requires the original native account receipt. An uncertain request is not automatically repeated."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(.localized("Checks the embedded profile before provisioning. If Apple returns the same expiry, the flow stops before key export or signing."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle(.localized("Approve one development certificate if no owned certificate exists (uses Apple quota)"), isOn: $consent.certificate)
            Toggle(.localized("Approve this device and App ID registration"), isOn: $consent.registration)
            Toggle(.localized("Approve a profile for this exact app, device and owned identity"), isOn: $consent.profile)

            if let blocked = consent.blockedReason(
                hasSession: contextID != nil,
                hasApp: true,
                isProvisioning: isProvisioning
            ) {
                Text(verbatim: blocked)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                if refreshReview {
                    Button {
                        guard provisioningTask == nil else { return }
                        provisioningTask = Task {
                            await runAccountRefresh()
                            provisioningTask = nil
                        }
                    } label: {
                        if isProvisioning {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text(.localized("Refreshing…"))
                            }
                        } else {
                            Label(.localized("Run Attended Refresh"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProvisioning || contextID == nil || !consent.approval.isComplete
                              || !consent.regeneration || !consent.keyExport || selectedApp?.isSigned != true)
                } else {
                    Button {
                        guard provisioningTask == nil else { return }
                        provisioningTask = Task {
                            await runProvisioning()
                            provisioningTask = nil
                        }
                    } label: {
                        if isProvisioning {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text(.localized("Provisioning…"))
                            }
                        } else {
                            Label(.localized("Start Provisioning"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProvisioning || (cellularReview && (!cellularAvailable || !consent.regeneration)) || contextID == nil || !consent.certificate || !consent.registration || !consent.profile)
                }

                Button(.localized("Back")) {
                    consent.certificate = false; consent.registration = false; consent.profile = false; consent.regeneration = false
                    step = .selectDevice
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Step 4: Provisioning

    var provisioningStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text(.localized("Provisioning in Progress"))
                .font(.title2.weight(.semibold))

            Text(provisioningStage.isEmpty ? .localized("Preparing…") : provisioningStage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ProgressView(value: provisioningProgress)
                .progressViewStyle(.linear)
                .padding(.horizontal)

            if let profile = createdProfile {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                    Text(.localized("Profile Created Successfully"))
                        .font(.title3.weight(.semibold))

                    Text("Profile UUID: \(profile.profileUUID.uuidString.prefix(8))...")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Button {
                        step = .complete
                    } label: {
                        Label(.localized("Review Profile Result"), systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Step 5: Complete

    var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: certificateImported ? "checkmark.seal.fill" : "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text(refreshReview
                 ? .localized("Refresh Processed")
                 : (certificateImported ? .localized("Certificate Imported") : .localized("Profile Recorded")))
                .font(.title.bold())

            Text(refreshReview
                 ? .localized("The attended refresh finished. A signed copy was handed to the delivery route you chose; verification below says what the device actually reported.")
                 : (certificateImported
                    ? .localized("The Apple ID identity and profile are now available in Certificates. Select them in the existing signing flow; this step did not sign or install an app.")
                    : .localized("Only the provisioning profile was recorded. No app has been signed or installed. Native Apple-account signing is experimental and not device-accepted. Import requires a separate key-export approval.")))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if refreshReview, let result = refreshResult {
                VStack(spacing: 8) {
                    Label(result.isVerified
                          ? .localized("The refresh has exact device evidence.")
                          : .localized("The refresh has no exact device evidence. Check the Home Screen; the outcome is recorded as unconfirmed."),
                          systemImage: result.isVerified ? "checkmark.seal.fill" : "questionmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(result.isVerified ? .green : .orange)
                    Text(.localized("Every stage was recorded in diagnostics with one correlation ID. No later stage was inferred from an earlier success."))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let handoff = signingHandoff {
                if let app = services.workspace.snapshot.apps.first(where: { handoff.matches($0) }) {
                    NavigationLink {
                        SigningView(app: app, accountHandoff: handoff)
                    } label: {
                        Label(.localized("Review Signing with This Identity"), systemImage: "signature")
                    }
                    .buttonStyle(.borderedProminent)
                    NavigationLink {
                        SigningView(app: app, installAfterSigning: true, accountHandoff: handoff)
                    } label: {
                        Label(.localized("Review Sign & Install"), systemImage: "arrow.down.app")
                    }
                    .buttonStyle(.bordered)
                    Text(.localized("The next review is bound to this app and the identity just imported. Nothing is signed until you approve it there. Installation has separate transport and trust requirements; unavailable paired routes are not unlocked."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(.localized("The provisioned app changed or is no longer in the library. Nothing was signed. Select the current app and review provisioning again."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !refreshReview && !certificateImported {
                Toggle(.localized("I consent to exporting this device-only private key once into VexSign's certificate store."), isOn: $consent.keyExport)
                    .disabled(isProvisioning)
                Button {
                    guard provisioningTask == nil else { return }
                    provisioningTask = Task {
                        await importCreatedCertificate()
                        provisioningTask = nil
                    }
                } label: {
                    if isProvisioning {
                        HStack { ProgressView(); Text(.localized("Validating & Importing…")) }
                    } else {
                        Label(.localized("Import Certificate & Profile"), systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProvisioning || !consent.keyExport)

                Text(.localized("Experimental: strict Apple CMS verification is configured. Genuine current Apple-profile compatibility and physical-device acceptance remain unverified; unsupported profiles are refused, not decoded as trusted plists."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(.localized("Done")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .disabled(isProvisioning)
        }
    }

    @MainActor
    private func importCreatedCertificate() async {
        guard let context = reviewedContextID, context == contextID, let profile = createdProfile, consent.keyExport, !certificateImported else { return }
        isProvisioning = true
        errorMessage = nil
        defer { isProvisioning = false }
        do {
            let result = try await manager.importCertificate(profile, consentGiven: consent.keyExport)
            guard !Task.isCancelled, contextID == context, reviewedContextID == context else { return }
            signingHandoff = result
            certificateImported = true
            consent.keyExport = false
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }
}
