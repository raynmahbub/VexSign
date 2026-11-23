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
    @EnvironmentObject var manager: AppleAccountWorkspaceModel
    @EnvironmentObject var services: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State var step: ProvisioningStep = .selectApp
    @State var selectedApp: AppInfoPresentable?
    @State var deviceIdentifier: String = ""
    @State var bundleIdentifier: String = ""
    @State var isProvisioning = false
    @State var provisioningTask: Task<Void, Never>?
    @State var provisioningProgress: Double = 0
    @State var provisioningStage: String = ""
    @State var errorMessage: String?
    @State var showAppPicker = false
    @State var showDevicePicker = false
    @State var createdProfile: AppleAccountProvisioningReceipt?
    @State var certificateImported = false
    @State var signingHandoff: AppleAccountSigningHandoff?
    @State var reviewedContextID: UUID?
    @State var approveCertificate = false
    @State var approveRegistration = false
    @State var approveProfile = false
    @State var requireLaterProfile = false
    @State var approveRegeneration = false
    @State var approveKeyExport = false

    let cellularReview: Bool
    @State var cellularAvailable = false

    init(cellularReview: Bool = false) {
        self.cellularReview = cellularReview
        _requireLaterProfile = State(initialValue: cellularReview)
    }

    // Context from signed-in state
    var contextID: UUID? {
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

    // MARK: - Provisioning Logic

    @MainActor
    func runProvisioning() async {
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
