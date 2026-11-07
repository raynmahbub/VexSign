import SwiftUI
import NimbleViews
import NimbleExtensions

struct SigningPreflightReviewView: View {
    let app: AppInfoPresentable
    let options: Options
    let certificate: CertificatePair?
    let result: PreflightResult
    let reviewOptions: () -> Void
    /// Starts the run. The flag says whether the user went through "Sign Anyway": the run then
    /// keeps its bundle even when the post-sign inspection repeats the issues accepted here.
    let sign: (_ overridingBlockingIssues: Bool) -> Void
    @State private var confirmOverride = false

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
                if result.isEmpty {
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
                Button {
                    if result.hasBlocking { confirmOverride = true } else { sign(false) }
                } label: {
                    Label(result.hasBlocking ? String.localized("Sign Anyway") : String.localized("Start Signing"),
                          systemImage: result.hasBlocking ? "exclamationmark.triangle" : "signature")
                        .frame(minHeight: 44)
                }
                .foregroundStyle(result.hasBlocking ? Color.red : Theme.tint)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(.localized("Ready to Sign"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { NBToolbarButton(role: .close) }
        .confirmationDialog(.localized("Continue despite blocking preflight issues?"), isPresented: $confirmOverride, titleVisibility: .visible) {
            Button(.localized("Sign Anyway"), role: .destructive) { sign(true) }
            Button(.localized("Cancel"), role: .cancel) {}
        }
    }
}
