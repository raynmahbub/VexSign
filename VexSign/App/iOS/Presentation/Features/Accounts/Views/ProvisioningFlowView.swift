// MARK: - ProvisioningFlowView
/// Experimental provisioning and certificate-store handoff. Requires separate
/// mutation/key-export approvals and Apple's strict CMS verifier. A successful
/// import offers an exact-identity transition to ordinary signing review; it
/// never starts signing/installation or claims physical acceptance by itself.

import SwiftUI
import NimbleViews
import NimbleExtensions
import UniformTypeIdentifiers

struct ProvisioningFlowView: View {
    @EnvironmentObject private var manager: AppleAccountWorkspaceModel
    @EnvironmentObject private var services: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var step: ProvisioningStep = .selectApp
    @State private var selectedApp: AppInfoPresentable?
    @State private var deviceIdentifier: String = ""
    @State private var bundleIdentifier: String = ""
    @State private var isProvisioning = false
    @State private var provisioningTask: Task<Void, Never>?
    @State private var provisioningProgress: Double = 0
    @State private var provisioningStage: String = ""
    @State private var errorMessage: String?
    @State private var showAppPicker = false
    @State private var showDevicePicker = false
    @State private var createdProfile: AppleAccountProvisioningReceipt?
    @State private var certificateImported = false
    @State private var signingHandoff: AppleAccountSigningHandoff?
    @State private var reviewedContextID: UUID?
    @State private var approveCertificate = false
    @State private var approveRegistration = false
    @State private var approveProfile = false
    @State private var requireLaterProfile = false
    @State private var approveRegeneration = false
    @State private var approveKeyExport = false

    let cellularReview: Bool
    @State private var cellularAvailable = false

    init(cellularReview: Bool = false) {
        self.cellularReview = cellularReview
        _requireLaterProfile = State(initialValue: cellularReview)
    }

    // Context from signed-in state
    private var contextID: UUID? {
        guard case .signedIn(let context) = manager.snapshot?.phase else { return nil }
        return context.id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Progress Header
                provisioningProgressHeader
                if cellularReview {
                    VStack {
                        Label(cellularAvailable ? .localized("Mobile data path available") : .localized("Waiting for a mobile data path"),
                              systemImage: "antenna.radiowaves.left.and.right")
                        Text(.localized("Turn off Wi-Fi and enable mobile data. This checks the default route before submission; it does not reset a VPN or verify installation."))
                        if contextID == nil {
                            Text(.localized("Sign in under Settings → Signing Methods before starting renewal."))
                        }
                    }.font(.caption).padding(.horizontal)
                }

                // Step Content
                ScrollView {
                    VStack(spacing: 24) {
                        switch step {
                        case .selectApp:
                            selectAppStep
                        case .selectDevice:
                            selectDeviceStep
                        case .review:
                            reviewStep
                        case .provisioning:
                            provisioningStep
                        case .complete:
                            completeStep
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(.localized("Provision & Sign"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                        .disabled(isProvisioning)
                }
            }
            .alert(.localized("Error"), isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
                Button(.localized("OK")) { errorMessage = nil }
            } message: { msg in
                Text(msg)
            }
            .interactiveDismissDisabled(isProvisioning)
            .onAppear { if cellularReview { cellularAvailable = DownloadPreferences.cellularPathAvailable } }
            .onReceive(NotificationCenter.default.publisher(for: DownloadPreferences.pathChanged)) { _ in
                if cellularReview { cellularAvailable = DownloadPreferences.cellularPathAvailable }
            }
            .onChange(of: contextID) { _, current in
                guard let reviewedContextID, current != reviewedContextID else { return }
                provisioningTask?.cancel()
                self.reviewedContextID = nil
                approveCertificate = false; approveRegistration = false; approveProfile = false
                approveKeyExport = false; approveRegeneration = false
                createdProfile = nil; signingHandoff = nil; certificateImported = false
                selectedApp = nil; deviceIdentifier = ""; step = .selectApp
                errorMessage = .localized("The Apple account session changed. Select the app and review permissions again.")
            }
            .onDisappear { provisioningTask?.cancel() }
            .sheet(isPresented: $showAppPicker) {
                AppPickerView(selectedApp: $selectedApp, signedOnly: cellularReview)
            }
            .sheet(isPresented: $showDevicePicker) {
                DevicePickerView(deviceIdentifier: $deviceIdentifier)
            }
        }
    }

    // MARK: - Progress Header

    private var provisioningProgressHeader: some View {
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

    private var selectAppStep: some View {
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

    private var selectDeviceStep: some View {
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

    private var reviewStep: some View {
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

            if selectedApp?.isSigned == true {
                Toggle(.localized("Require a later expiry than this signed library copy"), isOn: $requireLaterProfile)
                    .disabled(cellularReview)
                    .onChange(of: requireLaterProfile) { _, _ in approveRegeneration = false }
                if requireLaterProfile {
                    Toggle(.localized("Request one regeneration of this app’s existing Apple profile"), isOn: $approveRegeneration)
                    Text(.localized("Changes the profile on Apple’s portal. Requires the original native account receipt. An uncertain request is not automatically repeated."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(.localized("Checks the embedded profile before provisioning. If Apple returns the same expiry, the flow stops before key export or signing."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle(.localized("Approve one development certificate if no owned certificate exists (uses Apple quota)"), isOn: $approveCertificate)
            Toggle(.localized("Approve this device and App ID registration"), isOn: $approveRegistration)
            Toggle(.localized("Approve a profile for this exact app, device and owned identity"), isOn: $approveProfile)

            VStack(spacing: 12) {
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
                .disabled(isProvisioning || (cellularReview && (!cellularAvailable || !approveRegeneration)) || contextID == nil || !approveCertificate || !approveRegistration || !approveProfile)

                Button(.localized("Back")) {
                    approveCertificate = false; approveRegistration = false; approveProfile = false; approveRegeneration = false
                    step = .selectDevice
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Step 4: Provisioning

    private var provisioningStep: some View {
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

    private var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: certificateImported ? "checkmark.seal.fill" : "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text(certificateImported ? .localized("Certificate Imported") : .localized("Profile Recorded"))
                .font(.title.bold())

            Text(certificateImported
                ? .localized("The Apple ID identity and profile are now available in Certificates. Select them in the existing signing flow; this step did not sign or install an app.")
                : .localized("Only the provisioning profile was recorded. No app has been signed or installed. Native Apple-account signing is experimental and not device-accepted. Import requires a separate key-export approval."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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

            if !certificateImported {
                Toggle(.localized("I consent to exporting this device-only private key once into VexSign's certificate store."), isOn: $approveKeyExport)
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
                .disabled(isProvisioning || !approveKeyExport)

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
        guard let context = reviewedContextID, context == contextID, let profile = createdProfile, approveKeyExport, !certificateImported else { return }
        isProvisioning = true
        errorMessage = nil
        defer { isProvisioning = false }
        do {
            let result = try await manager.importCertificate(profile, consentGiven: approveKeyExport)
            guard !Task.isCancelled, contextID == context, reviewedContextID == context else { return }
            signingHandoff = result
            certificateImported = true
            approveKeyExport = false
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    // MARK: - Provisioning Logic

    @MainActor
    private func runProvisioning() async {
        guard let contextID, reviewedContextID == contextID, let app = selectedApp else {
            errorMessage = .localized("Missing context or app selection")
            return
        }
        if cellularReview && (!DownloadPreferences.cellularPathAvailable || !app.isSigned || !approveRegeneration) {
            errorMessage = .localized("Renewal requires a signed app, mobile data and explicit confirmation.")
            return
        }
        let approval = AppleAccountProvisioningApproval(certificate: approveCertificate,
            registration: approveRegistration, profile: approveProfile)
        guard approval.isComplete else { return }
        isProvisioning = true
        step = .provisioning
        defer { isProvisioning = false }
        provisioningProgress = 0
        errorMessage = nil
        do {
            let request = AppleAccountProvisioningRequest(contextID: contextID,
                app: try LibraryAppReference(app: app), deviceIdentifier: deviceIdentifier,
                requireLaterProfile: app.isSigned && requireLaterProfile,
                approveRegeneration: app.isSigned && requireLaterProfile && approveRegeneration)
            approveRegeneration = false // consume the UI confirmation even if the portal request fails
            let receipt = try await manager.provision(request, approval: approval) { progress in
                guard self.contextID == contextID, reviewedContextID == contextID else { return }
                updateStage(progress.stage.title, progress.fraction)
            }
            guard !Task.isCancelled, self.contextID == contextID, reviewedContextID == contextID else { return }
            createdProfile = receipt
        } catch {
            guard !Task.isCancelled, self.contextID == contextID, reviewedContextID == contextID else { return }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            step = .review
        }
    }

    @MainActor
    private func updateStage(_ stage: String, _ progress: Double) {
        provisioningStage = stage
        provisioningProgress = progress
    }
}

// MARK: - Supporting Views

private struct AppSelectionCard: View {
    @EnvironmentObject private var services: AppContainer
    let app: AppInfoPresentable
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let iconName = app.icon, let data = services.files.iconData(named: iconName), let uiImage = UIImage(data: data) { // try? ok: optional icon, falls back to placeholder
                Image(uiImage: uiImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .cornerRadius(12)
            } else {
                Image(systemName: "app.fill")
                    .font(.title)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(12)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name ?? .localized("Unknown"))
                    .font(.headline)
                Text(app.identifier ?? .localized("Unknown"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(app.version ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title2)
            }
        }
        .padding()
        .background(Color(uiColor: .quaternarySystemFill))
        .cornerRadius(14)
    }
}

private struct ReviewCard: View {
    let appName: String
    let bundleIdentifier: String
    let deviceUDID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReviewRow(label: .localized("App"), value: appName)
            ReviewRow(label: .localized("Bundle ID"), value: bundleIdentifier, monospaced: true)
            ReviewRow(label: .localized("Device UDID"), value: deviceUDID, monospaced: true)
            ReviewRow(label: .localized("Certificate"), value: .localized("Development (auto-generated)"))
            ReviewRow(label: .localized("Profile"), value: .localized("iOS Development (auto-generated)"))
        }
        .padding()
        .background(Color(uiColor: .quaternarySystemFill))
        .cornerRadius(14)
    }
}

private struct ReviewRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct AppPickerView: View {
    @EnvironmentObject var services: AppContainer
    @Binding var selectedApp: AppInfoPresentable?
    let signedOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var allApps: [AppInfoPresentable] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(allApps, id: \.uuid) { app in
                    Button {
                        selectedApp = app
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(app.name ?? .localized("Unknown"))
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(app.identifier ?? .localized("Unknown"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedApp?.uuid == app.uuid {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .dismissableKeyboard()
            .task {
                allApps = services.workspace.snapshot.apps.filter { !signedOnly || $0.isSigned }
            }
            .navigationTitle(.localized("Select App"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - ProvisioningStep

private enum ProvisioningStep: Int, CaseIterable {
    case selectApp = 1
    case selectDevice = 2
    case review = 3
    case provisioning = 4
    case complete = 5

    var order: Int { rawValue }

    var title: String {
        switch self {
        case .selectApp: return .localized("1. Select App")
        case .selectDevice: return .localized("2. Select Device")
        case .review: return .localized("3. Review")
        case .provisioning: return .localized("4. Provisioning")
        case .complete: return .localized("5. Complete")
        }
    }
}