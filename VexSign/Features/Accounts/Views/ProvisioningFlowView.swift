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
    @Environment(\.dismiss) var dismiss

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
    @State var refreshResult: AccountRefreshResult?
    @State var reviewedContextID: UUID?
    /// Every approval this flow collects, in one testable value.
    @State var consent: ProvisioningConsentState

    let cellularReview: Bool
    /// An attended account refresh reuses the review screens but runs the six-stage
    /// refresh pipeline instead of provisioning alone. It never starts from a Shortcut.
    let refreshReview: Bool
    /// An imported app that needs an Apple Account signing identity. Used to preselect
    /// the app after an attended-review request; it does not skip any approval.
    let initialAppUUID: String?
    @State var cellularAvailable = false

    init(cellularReview: Bool = false, refreshReview: Bool = false, initialAppUUID: String? = nil) {
        self.cellularReview = cellularReview
        self.refreshReview = refreshReview
        self.initialAppUUID = initialAppUUID
        var consent = ProvisioningConsentState(cellularReview: cellularReview)
        if refreshReview { consent.laterProfile = true }
        _consent = State(initialValue: consent)
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
                    }.font(.caption).padding(.horizontal)
                }
                // The wizard used to open with every action disabled and, outside
                // renewal mode, not one word about why; the only sign-in hint was
                // inside the renewal banner. One sentence from the same value that
                // disables the buttons answers it on both paths.
                if contextID == nil {
                    Label(.localized("Sign in under Settings → Signing Methods, then choose the app to provision."), systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            .navigationTitle(refreshReview ? .localized("Refresh Account Signature") : .localized("Provision & Sign"))
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
            .onAppear {
                if cellularReview { cellularAvailable = DownloadPreferences.cellularPathAvailable }
                guard let initialAppUUID, selectedApp == nil,
                      let match = services.workspace.snapshot.apps.first(where: { $0.uuid == initialAppUUID }) else { return }
                selectedApp = match
                step = .selectDevice
            }
            .onReceive(NotificationCenter.default.publisher(for: DownloadPreferences.pathChanged)) { _ in
                if cellularReview { cellularAvailable = DownloadPreferences.cellularPathAvailable }
            }
            .onChange(of: contextID) { _, current in
                guard let reviewedContextID, current != reviewedContextID else { return }
                provisioningTask?.cancel()
                self.reviewedContextID = nil
                // Every approval belongs to the account that granted it, so a
                // session change clears them all in one place.
                consent.reset()
                createdProfile = nil; signingHandoff = nil; certificateImported = false
                refreshResult = nil
                selectedApp = nil; deviceIdentifier = ""; step = .selectApp
                errorMessage = .localized("The Apple account session changed. Select the app and review permissions again.")
            }
            .onDisappear { provisioningTask?.cancel() }
            .sheet(isPresented: $showAppPicker) {
                AppPickerView(selectedApp: $selectedApp, signedOnly: cellularReview || refreshReview)
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
        if cellularReview && (!DownloadPreferences.cellularPathAvailable || !app.isSigned || !consent.regeneration) {
            errorMessage = .localized("Renewal requires a signed app, mobile data and explicit confirmation.")
            return
        }
        // The approval object and the disabled state of the button are derived
        // from the same value, so the flow cannot start with a consent the screen
        // has not shown.
        let approval = consent.approval
        guard approval.isComplete else { return }
        isProvisioning = true
        step = .provisioning
        defer { isProvisioning = false }
        provisioningProgress = 0
        errorMessage = nil
        do {
            let request = AppleAccountProvisioningRequest(contextID: contextID,
                app: try LibraryAppReference(app: app), deviceIdentifier: deviceIdentifier,
                requireLaterProfile: app.isSigned && consent.laterProfile,
                approveRegeneration: app.isSigned && consent.laterProfile && consent.regeneration)
            consent.regeneration = false // consume the UI confirmation even if the portal request fails
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
    func updateStage(_ stage: String, _ progress: Double) {
        provisioningStage = stage
        provisioningProgress = progress
    }
}
