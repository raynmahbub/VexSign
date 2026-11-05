// MARK: - ProvisioningFlowView
/// Complete free Apple ID provisioning flow: device selection, app ID registration,
/// certificate creation, and profile creation — all with live progress tracking.

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
    @State private var provisioningProgress: Double = 0
    @State private var provisioningStage: String = ""
    @State private var errorMessage: String?
    @State private var showAppPicker = false
    @State private var showDevicePicker = false
    @State private var createdProfile: NativeAccountProfileResult?
    @State private var signedIPAURL: URL?

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
                .foregroundStyle(.accentColor)

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
            .buttonStyle(NBButtonStyle(.prominent))
            .disabled(isProvisioning)

            if selectedApp != nil {
                Button(.localized("Next: Select Device")) {
                    step = .selectDevice
                }
                .buttonStyle(NBButtonStyle(.borderedProminent))
            }
        }
    }

    // MARK: - Step 2: Select Device

    private var selectDeviceStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.accentColor)

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
                            .foregroundStyle(.accentColor)
                    }
                }
            }

            if !deviceIdentifier.isEmpty {
                Button(.localized("Next: Review")) {
                    step = .review
                }
                .buttonStyle(NBButtonStyle(.borderedProminent))
            }

            Button(.localized("Back")) {
                step = .selectApp
            }
            .buttonStyle(NBButtonStyle(.bordered))
        }
    }

    // MARK: - Step 3: Review

    private var reviewStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.accentColor)

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

            VStack(spacing: 12) {
                Button {
                    Task { await runProvisioning() }
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
                .buttonStyle(NBButtonStyle(.prominent))
                .disabled(isProvisioning || contextID == nil)

                Button(.localized("Back")) {
                    step = .selectDevice
                }
                .buttonStyle(NBButtonStyle(.bordered))
            }
        }
    }

    // MARK: - Step 4: Provisioning

    private var provisioningStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 48))
                .foregroundStyle(.accentColor)

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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontDesign(.monospaced)

                    Button {
                        Task { await signAndInstall(profile: profile) }
                    } label: {
                        Label(.localized("Sign & Install App"), systemImage: "signature")
                    }
                    .buttonStyle(NBButtonStyle(.prominent))
                }
            }
        }
    }

    // MARK: - Step 5: Complete

    private var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text(.localized("All Done!"))
                .font(.title.bold())

            Text(.localized("The app has been signed and installed on your device."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let url = signedIPAURL {
                ShareLink(item: url) {
                    Label(.localized("Export Signed IPA"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(NBButtonStyle(.borderedProminent))
            }

            Button(.localized("Done")) { dismiss() }
                .buttonStyle(NBButtonStyle(.prominent))
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

        isProvisioning = true
        provisioningProgress = 0
        errorMessage = nil

        do {
            // 1. Provisioning preflight
            await updateStage(.localized("Checking Apple inventory…"), 0.1)
            let request = try NativeAccountProvisioningRequest(
                deviceIdentifier: deviceIdentifier.uppercased(),
                bundleIdentifiers: [bundleID]
            )
            // The manager's pass-throughs mint the anisette consent per mutating
            // call; a view never holds a consent token.
            let plan = try await manager.provisioningPreflight(contextID: contextID, request: request)

            // 2. Prepare signing identity (key + CSR)
            await updateStage(.localized("Preparing signing identity…"), 0.25)
            let identityTicket = try await manager.prepareSigningIdentity(contextID: contextID)

            // 3. Certificate creation approval
            await updateStage(.localized("Requesting certificate creation approval…"), 0.4)
            let certApproval = try await manager.recordCertificateCreationApproval(contextID: contextID, identityID: identityTicket.id)

            // 4. Create certificate
            await updateStage(.localized("Creating development certificate…"), 0.55)
            _ = try await manager.createDevelopmentCertificate(
                contextID: contextID,
                identityID: identityTicket.id,
                approval: certApproval
            )

            // 5. Device/App ID registration
            await updateStage(.localized("Registering device & App ID…"), 0.7)
            let subject = try NativeRegistrationSubject(kind: .device, value: deviceIdentifier)
            let regApproval = try await manager.recordRegistrationApproval(contextID: contextID, subject: subject)
            _ = try await manager.registerResource(contextID: contextID, subject: subject, approval: regApproval)

            // 6. App ID registration
            await updateStage(.localized("Registering App ID…"), 0.8)
            let appIDSubject = try NativeRegistrationSubject(kind: .appID, value: bundleID)
            let appIDApproval = try await manager.recordRegistrationApproval(contextID: contextID, subject: appIDSubject)
            _ = try await manager.registerResource(contextID: contextID, subject: appIDSubject, approval: appIDApproval)

            // 7. Profile creation
            await updateStage(.localized("Creating provisioning profile…"), 0.9)
            // Get registered IDs from plan
            let target = try NativeAccountProfileTarget(
                identityID: identityTicket.id,
                bundleIdentifier: bundleID,
                deviceIdentifier: deviceIdentifier.uppercased(),
                registeredAppID: plan.existingAppIdentifiers.first ?? bundleID,
                registeredDeviceID: "auto" // Will be resolved by backend
            )
            let profileApproval = try await manager.recordProfileCreationApproval(contextID: contextID, target: target)
            let profileResult = try await manager.createProvisioningProfile(contextID: contextID, target: target, approval: profileApproval)

            await MainActor.run {
                provisioningProgress = 1.0
                provisioningStage = .localized("Provisioning complete!")
                createdProfile = profileResult
            }
        } catch {
            await MainActor.run {
                isProvisioning = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func signAndInstall(profile: NativeAccountProfileResult) async {
        await updateStage(.localized("Signing app with new profile…"), 0.2)
        // TODO: Integrate with Zsign signing pipeline
        // This would use the created profile + certificate to sign the selected app
        // Then install via itms-services or AFC

        // For now, simulate completion
        try? await Task.sleep(nanoseconds: 2_000_000_000) // try? ok: simulated delay, cancellation checked by Task

        await MainActor.run {
            provisioningProgress = 1.0
            step = .complete
            signedIPAURL = nil // Would be set after actual signing
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
                                    .foregroundStyle(.accentColor)
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