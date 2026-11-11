// MARK: - ProvisioningFlowView
/// Experimental provisioning and certificate-store handoff. Requires separate
/// mutation/key-export approvals and a configured CMS verifier; does not start
/// signing/installation or claim native account signing is integrated.

import SwiftUI
import NimbleViews
import NimbleExtensions
import NativeSigning
import UniformTypeIdentifiers

struct ProvisioningFlowView: View {
    @StateObject private var manager = NativeSigningManager.shared
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
    @State private var createdProfile: NativeAccountProfileResult?
    @State private var createdIdentityID: UUID?
    @State private var certificateImported = false
    @State private var approveCertificate = false
    @State private var approveRegistration = false
    @State private var approveProfile = false
    @State private var approveKeyExport = false

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
            .onDisappear { provisioningTask?.cancel() }
            .sheet(isPresented: $showAppPicker) {
                AppPickerView(selectedApp: $selectedApp)
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
                }
            }

            if !deviceIdentifier.isEmpty {
                Button(.localized("Next: Review")) {
                    step = .review
                }
                .buttonStyle(.borderedProminent)
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
                .disabled(isProvisioning || contextID == nil || !approveCertificate || !approveRegistration || !approveProfile)

                Button(.localized("Back")) {
                    approveCertificate = false; approveRegistration = false; approveProfile = false
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
                : .localized("Only the provisioning profile was recorded. No app has been signed or installed. Native signing handoff is not enabled in this build."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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

                Text(.localized("Experimental: production CMS verification and physical-device acceptance are still required before native Apple-account signing is considered integrated."))
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
        guard let contextID, let app = selectedApp, let bundleID = app.identifier,
              let profile = createdProfile, let identityID = createdIdentityID,
              approveKeyExport, !certificateImported else { return }
        isProvisioning = true
        errorMessage = nil
        defer { isProvisioning = false }
        do {
            let consent = try await manager.recordKeyExportConsent(contextID: contextID, identityID: identityID)
            try await manager.exportToCertificateStore(contextID: contextID, profile: profile,
                identityID: identityID, bundleIdentifier: bundleID,
                deviceIdentifier: deviceIdentifier.uppercased(), consent: consent)
            certificateImported = true
            approveKeyExport = false
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    // MARK: - Provisioning Logic

    private func runProvisioning() async {
        guard let contextID = contextID,
              let app = selectedApp,
              let bundleID = app.identifier else {
            errorMessage = .localized("Missing context or app selection")
            return
        }

        guard approveCertificate, approveRegistration, approveProfile else { return }
        isProvisioning = true
        step = .provisioning
        defer { isProvisioning = false }
        provisioningProgress = 0
        errorMessage = nil

        do {
            // Do not consume quota before the required CMS capability exists.
            try await manager.requireProfileOperations()
            // 1. Provisioning preflight
            updateStage(.localized("Checking Apple inventory…"), 0.1)
            let request = try NativeAccountProvisioningRequest(
                deviceIdentifier: deviceIdentifier.uppercased(),
                bundleIdentifiers: [bundleID]
            )
            // The manager's pass-throughs mint the anisette consent per mutating
            // call; a view never holds a consent token.
            _ = try await manager.provisioningPreflight(contextID: contextID, request: request)

            // 2. Prepare signing identity (key + CSR)
            updateStage(.localized("Preparing signing identity…"), 0.25)
            let identityTicket = try await manager.prepareSigningIdentity(contextID: contextID)

            // Reuse recorded ownership; uncertainty is reconciled, never rotated.
            switch identityTicket.phase {
            case .prepared:
                updateStage(.localized("Requesting certificate creation approval…"), 0.4)
                let approval = try await manager.recordCertificateCreationApproval(contextID: contextID, identityID: identityTicket.id)
                _ = try await manager.createDevelopmentCertificate(contextID: contextID, identityID: identityTicket.id, approval: approval)
            case .submissionUncertain:
                _ = try await manager.reconcileCertificate(contextID: contextID, identityID: identityTicket.id)
            case .certificateRecorded:
                break
            }

            // 5. Device/App ID registration
            updateStage(.localized("Registering device & App ID…"), 0.7)
            let subject = try NativeRegistrationSubject(kind: .device, value: deviceIdentifier)
            let regApproval = try await manager.recordRegistrationApproval(contextID: contextID, subject: subject)
            let deviceRegistration = try await manager.registerResource(contextID: contextID, subject: subject, approval: regApproval)

            // 6. App ID registration
            updateStage(.localized("Registering App ID…"), 0.8)
            let appIDSubject = try NativeRegistrationSubject(kind: .appID, value: bundleID)
            let appIDApproval = try await manager.recordRegistrationApproval(contextID: contextID, subject: appIDSubject)
            let appRegistration = try await manager.registerResource(contextID: contextID, subject: appIDSubject, approval: appIDApproval)

            // 7. Profile creation
            updateStage(.localized("Creating provisioning profile…"), 0.9)
            // Carry the actual opaque registration results into the bound target.
            let target = try NativeAccountProfileTarget(
                identityID: identityTicket.id,
                bundleIdentifier: bundleID,
                deviceIdentifier: deviceIdentifier.uppercased(),
                appRegistration: appRegistration,
                deviceRegistration: deviceRegistration
            )
            let profileApproval = try await manager.recordProfileCreationApproval(contextID: contextID, target: target)
            let profileResult = try await manager.createProvisioningProfile(contextID: contextID, target: target, approval: profileApproval)

            await MainActor.run {
                provisioningProgress = 1.0
                provisioningStage = .localized("Provisioning complete!")
                createdProfile = profileResult
                createdIdentityID = identityTicket.id
            }
        } catch {
            await MainActor.run {
                isProvisioning = false
                errorMessage = error.localizedDescription
                step = .review
            }
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
    let app: AppInfoPresentable
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let iconName = app.icon, let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Icons/\(iconName)"),
               let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) { // try? ok: optional icon, falls back to placeholder
                Image(uiImage: uiImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .cornerRadius(12)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 28))
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
    @Binding var selectedApp: AppInfoPresentable?
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(
        entity: Imported.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
        animation: .snappy
    ) private var importedApps: FetchedResults<Imported>
    @FetchRequest(
        entity: Signed.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
        animation: .snappy
    ) private var signedApps: FetchedResults<Signed>

    var allApps: [AppInfoPresentable] {
        Array(importedApps) + Array(signedApps)
    }

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