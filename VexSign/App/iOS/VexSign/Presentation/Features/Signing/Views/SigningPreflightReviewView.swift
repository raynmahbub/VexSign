import SwiftUI
import NimbleViews
import NimbleExtensions

struct SigningPreflightReviewView: View {
    @EnvironmentObject var services: AppContainer
    let app: AppInfoPresentable
    let options: Options
    let certificate: CertificateRecord?
    let result: PreflightResult
    let reviewOptions: () -> Void
    /// Starts the run. The flag says whether the user went through "Sign Anyway": the run then
    /// keeps its bundle even when the post-sign inspection repeats the issues accepted here.
    let sign: (_ overridingBlockingIssues: Bool) -> Void
    @State private var confirmOverride = false
    @State private var isAuditing = true
    @State private var executableFindings: [BundleExecutableAudit.Finding] = []
    @State private var auditFailure: String?
    @State private var workingSpace: String?

    var body: some View {
        List {
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
                LabeledContent(.localized("App extensions"), value: options.removeAppExtensions ? String.localized("Remove all") : (options.autoRemoveUnsupportedExtensions ? String.localized("Keep compatible; remove unsupported") : String.localized("Keep all")))
                LabeledContent(.localized("Injected files"), value: options.injectionFiles.count.description)
                    .monospacedDigit()
                Text(options.post_installAppAfterSigned
                     ? .localized("After signing, VexSign will request installation. Installation must be confirmed separately.")
                     : .localized("A signed copy will be produced. Choose an action on the result screen."))
                    .foregroundStyle(.secondary)
            } header: { Text(.localized("Review changes")) }
            Section {
                if let certificate {
                    CertificatesCellView(cert: certificate)
                } else {
                    Text(.localized("No certificate selected. Whether one is required depends on your signing mode."))
                }
            } header: { Text(.localized("Signing identity")) }
            Section {
                if isAuditing { ProgressView(.localized("Inspecting executable slices and working space…")) }
                if let workingSpace { Text(workingSpace).font(.caption).foregroundStyle(.secondary) }
                if let auditFailure { Text(auditFailure).foregroundStyle(.red) }
                ForEach(executableFindings) { finding in
                    Label(finding.detail, systemImage: finding.isBlocking ? "xmark.octagon" : "exclamationmark.triangle")
                        .foregroundStyle(finding.isBlocking ? Color.red : .orange)
                }
                if result.isEmpty && !isAuditing && executableFindings.isEmpty && auditFailure == nil {
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
                    }
                    .padding(.vertical, Theme.Spacing.xSmall)
                }
                Button(.localized("Review certificate and options"), action: reviewOptions)
                    .keyboardShortcut(.cancelAction)
            } header: { Text(.localized("Preflight checks")) }
            Section {
                if result.hasMandatoryFailure {
                    // iOS enforces these at install, so there is nothing to sign through:
                    // the result would be a signed copy that cannot be installed.
                    Label(.localized("This app cannot be signed with the current certificate and profile."),
                          systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(A11y.Signing.preflightCannotSign)
                    Text(.localized("Resolve the issues marked above, then review again. Changing the certificate, the bundle identifier or the extension options are the usual fixes."))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button {
                        if result.canSignAnyway { confirmOverride = true } else { sign(false) }
                    } label: {
                        Label(result.canSignAnyway ? String.localized("Sign Anyway") : String.localized("Start Signing"),
                              systemImage: result.canSignAnyway ? "exclamationmark.triangle" : "signature")
                            .frame(minHeight: 44)
                    }
                    .foregroundStyle(result.canSignAnyway ? Color.red : Theme.tint)
                    .disabled(isAuditing || auditFailure != nil || executableFindings.contains(where: { $0.isBlocking }))
                }
            }
        }
        .task { await inspectExecutables() }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(.localized("Ready to Sign"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NBToolbarButton(role: .close) }
        .confirmationDialog(.localized("Continue despite blocking preflight issues?"), isPresented: $confirmOverride, titleVisibility: .visible) {
            Button(.localized("Sign Anyway"), role: .destructive) { sign(true) }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(.localized("The signed copy may not install or launch. The final signature check still applies and can reject the result."))
        }
    }
    @MainActor
    private func inspectExecutables() async {
        guard options.signingOption != .onlyModify else { isAuditing = false; return }
        do {
            let evidence = try await services.signing.inspect(app: app, options: options, certificate: certificate)
            let report = evidence.report
            let required = evidence.requiredBytes
            try Task.checkCancellation()
            executableFindings = report.findings
            workingSpace = String.localized("Estimated signing working space: %@. This is not a disk reservation.",
                arguments: ByteCountFormatter.string(fromByteCount: required, countStyle: .file))
            isAuditing = false
        } catch {
            guard !Task.isCancelled else { return }
            auditFailure = LogRedaction.redact(error.localizedDescription)
            isAuditing = false
        }
    }

}
