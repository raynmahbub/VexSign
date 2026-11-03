import SwiftUI
import NimbleViews
import NimbleExtensions

/// Shares Settings' navigation stack. No credential entry until a native
/// authentication/provisioning adapter is actually connected.
struct SigningMethodsView: View {
    private var capabilities: SigningMethodCapabilities { .current }

    var body: some View {
        NBList(.localized("Signing Methods")) {
            Section {
                Label(.localized("Imported certificate signing is implemented"), systemImage: "signature")
                Text(.localized("Use an imported signing identity and provisioning profile. Validity, device authorization, entitlements and installation must be checked separately. An imported certificate is not automatically a paid certificate."))
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink(destination: CertificatesView()) {
                    Label(.localized("Certificates Manager"), systemImage: "checkmark.seal")
                }
            } header: { Text(.localized("Certificate-based signing")) }

            Section {
                Label(.localized("Native Apple-account signing is not integrated yet"), systemImage: "person.crop.circle.badge.exclamationmark")
                Text(.localized("Installing VexSign with a free Apple account does not enable account signing inside VexSign. Native authentication, team selection, provisioning, installation and renewal still need integration. No Apple password is requested on this screen."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(.localized("Free and paid teams must be selected explicitly. Apple provisioning restrictions, expiry and background limits still apply."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text(.localized("Apple-account signing")) }

            Section {
                Label(.localized("VexSign as the primary container host is not integrated yet"), systemImage: "square.stack")
                switch capabilities.experimentalRuntime {
                case .none:
                    Text(.localized("This app does not contain the experimental guest-host runtime. External companion detection is not embedded hosting."))
                case .guestPrototypeUnavailable:
                    Text(.localized("This is an experimental guest copy, but its compatible host runtime is unavailable. It is not the final VexSign-primary-host architecture."))
                case .guestPrototypeLoaded:
                    Text(.localized("The experimental guest-host runtime is loaded. VexSign is still a guest in that prototype, not the primary host required by the all-in-one design."))
                }
                NavigationLink(destination: CompanionSigningWorkflowView()) {
                    Label(.localized("SideStore & LiveContainer"), systemImage: "arrow.triangle.branch")
                }
            } header: { Text(.localized("App hosting")) }
        }
    }
}
