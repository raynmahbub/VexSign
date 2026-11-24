import SwiftUI
import NimbleExtensions

struct EcosystemView: View {
    @AppStorage("VexSign.ecosystem.repositoryAutoRefresh") private var autoRefresh = false
    var body: some View {
        List {
            Section(.localized("Publish & Discover")) {
                NavigationLink(destination: RepositoryBuilderView()) { Label(.localized("Repository Builder"), systemImage: "shippingbox") }
                NavigationLink(destination: DiscoveryView()) { Label(.localized("Discovery"), systemImage: "sparkles") }
            }
            Section(.localized("Repository Sync")) {
                Toggle(.localized("Automatic Six-Hour Refresh"), isOn: $autoRefresh)
                    .onChange(of: autoRefresh) { _, _ in EcosystemMaintenance.schedule() }
                Text(.localized("Refreshes at startup and during available background time. iOS controls the actual schedule. Game Mode pauses network work.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(.localized("Signing Tools")) {
                NavigationLink(destination: CertificateDashboardView()) { Label(.localized("Certificate Health"), systemImage: "checkmark.shield") }
                NavigationLink(destination: OTAView()) { Label(.localized("OTA Distribution"), systemImage: "qrcode") }
                NavigationLink(destination: CloneWizardView()) { Label(.localized("Clone Wizard"), systemImage: "square.on.square") }
                NavigationLink(destination: AnalyticsView()) { Label(.localized("Analytics"), systemImage: "chart.bar") }
            }
            Section(.localized("Web Tools")) {
                NavigationLink(destination: WebToolsView()) { Label(.localized("Repository Creator, Certificate Checker, UDID"), systemImage: "globe") }
                Text(.localized("Browser tools served by the VexSign backend under /tools. They run on the server: no private key ever leaves your device, and the repository creator hands you a file instead of hosting your IPAs.")).font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(.localized("Ecosystem"))
    }
}
