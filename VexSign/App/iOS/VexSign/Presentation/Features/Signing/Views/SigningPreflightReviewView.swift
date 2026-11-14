import SwiftUI
import NimbleViews
import NimbleExtensions

struct SigningPreflightReviewView: View {
    let app: AppInfoPresentable
    @Binding var options: Options
    let certificate: CertificateRecord?
    let readiness: SigningReadiness
    let reviewOptions: () -> Void
    let refresh: () -> Void
    /// Approval carries the exact reviewed component/asset/removal binding.
    let sign: (_ overridingBlockingIssues: Bool, _ authorization: SigningResolutionAuthorization?) -> Void
    @State private var confirmOverride = false
    @State private var confirmRemoval = false
    @State private var pendingAuthorization: SigningResolutionAuthorization?
    @State private var pendingSetup: SigningPreflightSnapshot?
    private var resolution: SigningResolutionReview? { readiness.resolution }
    private var result: PreflightResult { readiness.preflight }
    private var executableFindings: [BundleExecutableAudit.Finding] { readiness.evidence?.report.findings ?? [] }

    var body: some View {
        List {
            Section {
                Label(readiness.state.title, systemImage: readiness.state.symbol)
                    .foregroundStyle(readiness.state.color)
                    .font(.headline)
                    .accessibilityIdentifier("signing.review.state")
                Text("Signing checks do not establish device trust, a successful installation, or successful launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(.localized("Application"), value: app.name ?? .localized("Application"))
                LabeledContent(.localized("Bundle identifier")) {
                    Text(options.appIdentifier ?? app.identifier ?? .localized("Unknown"))
                        .font(.body.monospaced()).textSelection(.enabled)
                }
                if let original = app.identifier, let changed = options.appIdentifier, original != changed {
                    Text(String.localized("Original identifier: %@", arguments: original))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                LabeledContent(.localized("App extensions"), value: options.removeAppExtensions || options.autoRemoveUnsupportedExtensions
                    ? String.localized("Only explicitly reviewed optional removals") : String.localized("Keep all"))
                LabeledContent(.localized("Injected files"), value: options.injectionFiles.count.description)
                    .monospacedDigit()
                Text(options.post_installAppAfterSigned
                     ? .localized("After signing, VexSign will request installation. Installation must be confirmed separately.")
                     : .localized("The verified signed copy will remain in Library → Signed. Signing does not install or launch it."))
                    .foregroundStyle(.secondary)
            } header: { Text(.localized("Review changes")) }
            Section {
                if let certificate {
                    CertificatesCellView(cert: certificate)
                    Text(options.automaticallyResolveSigningIdentity != false
                         ? .localized("This is the preferred identity only. The authenticated identities and profiles actually selected are listed for each component below.")
                         : .localized("This identity is required. Every component still needs an authenticated compatible profile and accessible matching private key."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(.localized("No certificate selected. Whether one is required depends on your signing mode."))
                }
            } header: { Text(.localized("Signing identity")) }
            if let resolution {
                Section("Component profiles") {
                    ForEach(resolution.components) { component in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(component.id == "." ? "Main application" : component.id,
                                  systemImage: component.status == .valid ? "checkmark.circle" : "xmark.octagon")
                                .foregroundStyle(component.status == .valid ? Color.green : .red)
                                .font(.headline)
                            Text(component.bundleIdentifier).font(.body.monospaced()).textSelection(.enabled)
                            if let profile = component.profileName { LabeledContent("Profile", value: profile) }
                            if let identity = component.certificateName { LabeledContent("Certificate", value: identity) }
                            if let uuid = component.profileUUID { LabeledContent("Profile UUID", value: uuid).font(.caption.monospaced()) }
                            if !component.choices.isEmpty || component.selectedChoice != nil {
                                Picker("Profile and identity", selection: preferenceBinding(for: component)) {
                                    Text("Automatic: best valid match").tag("")
                                    ForEach(component.choices) { choice in
                                        Text(choice.profileName + " · " + choice.certificateName).tag(choice.id)
                                    }
                                    if let selected = component.selectedChoice, !component.choices.contains(where: { $0.id == selected }) {
                                        Text("Selected asset unavailable or incompatible").tag(selected)
                                    }
                                }
                                .pickerStyle(.menu)
                                .accessibilityIdentifier("signing.review.choice." + component.id)
                            }
                            if let team = component.team { LabeledContent("Team", value: team) }
                            if let expiration = component.profileExpiration { LabeledContent("Profile expires", value: expiration.formatted(date: .abbreviated, time: .omitted)) }
                            if let expiration = component.certificateExpiration { LabeledContent("Certificate expires", value: expiration.formatted(date: .abbreviated, time: .omitted)) }
                            if !component.entitlementKeys.isEmpty {
                                Text(component.entitlementKeys.joined(separator: ", ")).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            Text(component.deviceAuthorization).font(.caption).foregroundStyle(.secondary)
                            if component.status == .valid { Text("Required entitlements authorized").font(.caption) }
                            ForEach(component.issues, id: \.self) { Text(LogRedaction.redact($0)).foregroundStyle(.red) }
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(resolution.inventoryNotices, id: \.self) { notice in
                        Label(LogRedaction.redact(notice), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                if !resolution.plannedRemovals.isEmpty {
                    Section("Optional extensions to remove") {
                        ForEach(resolution.plannedRemovals, id: \.self) { Text($0).font(.body.monospaced()) }
                        Text("These extensions will be removed from the working copy only. Their widgets or sharing features will be unavailable. Keep all extensions by importing compatible profiles instead.")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                if readiness.isChecking { ProgressView(.localized("Inspecting profiles, identities, executable slices and working space…")) }
                if let required = readiness.evidence?.requiredBytes, required > 0 {
                    Text(String.localized("Estimated signing working space: %@. This is not a disk reservation.",
                        arguments: ByteCountFormatter.string(fromByteCount: required, countStyle: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failure = readiness.auditFailure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                ForEach(executableFindings) { finding in
                    Label(finding.detail, systemImage: finding.isBlocking ? "xmark.octagon" : "exclamationmark.triangle")
                        .foregroundStyle(finding.isBlocking ? Color.red : .orange)
                }
                if readiness.state == .ready {
                    Label(.localized("No preflight issues found"), systemImage: "checkmark.circle")
                    Text(.localized("Preflight checks do not guarantee successful signing or installation."))
                        .foregroundStyle(.secondary)
                }
                ForEach(result.issues) { issue in
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Label(issue.title, systemImage: issue.severity == .blocking ? "xmark.octagon" : "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(issue.severity == .blocking ? Color.red : .orange)
                        Text(LogRedaction.redact(issue.detail)).textSelection(.enabled)
                        if let remediation = issue.remediation { Text(remediation).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, Theme.Spacing.xSmall)
                }
                Button(.localized("Review certificate and options"), action: reviewOptions)
                    .keyboardShortcut(.cancelAction)
                Text(.localized("Open Certificates and use + → Certificate Files to import a compatible identity, or Get Info → Extension Profiles for its component profiles. Then check again."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(.localized("Check Again"), action: refresh).disabled(readiness.isChecking)
            } header: { Text(.localized("Preflight checks")) }
            Section {
                if readiness.state == .blocked {
                    Label(.localized("This app cannot be signed with the current certificate and profile."),
                          systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(A11y.Signing.preflightCannotSign)
                    Text(.localized("Import compatible Apple-issued profiles and matching identities for every retained component, then review again. Original Bundle Identifiers will not be changed to bypass provisioning."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(action: requestApproval) {
                    Label(result.canSignAnyway ? String.localized("Sign Anyway") : String.localized("Start Signing"),
                          systemImage: result.canSignAnyway ? "exclamationmark.triangle" : "signature")
                        .frame(minHeight: 44)
                }
                .foregroundStyle(result.canSignAnyway ? Color.red : Theme.tint)
                .disabled(!readiness.canApprove)
                .accessibilityIdentifier("signing.review.approve")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(.localized("Ready to Sign"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NBToolbarButton(role: .close) }
        .confirmationDialog("Remove the listed optional extensions?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove listed extensions and sign", role: .destructive) {
                guard approvalStillMatches else { refresh(); return }
                if result.canSignAnyway { confirmOverride = true } else { approve(false) }
            }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text((pendingAuthorization?.plannedRemovals ?? []).joined(separator: "\n") + "\nThe original library copy is unchanged. Extension functionality will be lost in the signed copy.")
        }
        .confirmationDialog(.localized("Continue despite blocking preflight issues?"), isPresented: $confirmOverride, titleVisibility: .visible) {
            Button(.localized("Sign Anyway"), role: .destructive) { approve(true) }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("The signed copy may not install or launch. The final signature check still applies and can reject the result."))
        }
    }
    private func requestApproval() {
        guard readiness.canApprove else { return }
        pendingAuthorization = resolution?.authorization
        pendingSetup = SigningPreflightSnapshot(options: options, certificateUUID: certificate?.uuid, issues: result.issues)
        if resolution?.plannedRemovals.isEmpty == false { confirmRemoval = true }
        else if result.canSignAnyway { confirmOverride = true }
        else { approve(false) }
    }

    private var approvalStillMatches: Bool {
        readiness.canApprove && pendingAuthorization == resolution?.authorization
            && pendingSetup?.matches(options: options, certificateUUID: certificate?.uuid, issues: result.issues) == true
    }

    private func approve(_ overridingBlockingIssues: Bool) {
        guard approvalStillMatches else { refresh(); return }
        sign(overridingBlockingIssues, pendingAuthorization)
    }

    private func preferenceBinding(for component: SigningComponentReview) -> Binding<String> {
        Binding(get: { options.componentSigningPreferences?[component.id]?.id ?? "" }, set: { selection in
            var preferences = options.componentSigningPreferences ?? [:]
            preferences[component.id] = component.choices.first(where: { $0.id == selection })?.preference
            options.componentSigningPreferences = preferences.isEmpty ? nil : preferences
        })
    }

}

extension SigningReadiness.State {
    var title: String {
        switch self {
        case .checking: .localized("Checking…")
        case .ready: .localized("Ready")
        case .warning: .localized("Warning")
        case .blocked: .localized("Blocked")
        }
    }
    var symbol: String {
        switch self {
        case .checking: "hourglass"
        case .ready: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .blocked: "xmark.octagon"
        }
    }
    var color: Color {
        switch self {
        case .checking: .secondary
        case .ready: .green
        case .warning: .orange
        case .blocked: .red
        }
    }
}
