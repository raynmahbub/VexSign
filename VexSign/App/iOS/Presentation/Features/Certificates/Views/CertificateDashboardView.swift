import SwiftUI
import NimbleExtensions

struct CertificateDashboardView: View {
    @EnvironmentObject var services: AppContainer
    var body: some View { CertificateDashboardContent(certificates: services.certificates) }
}

private struct CertificateDashboardContent: View {
    @ObservedObject var certificates: CertificateWorkspaceModel
    @State private var health: [CertificateHealth] = []
    @State private var errors: [String] = []
    @State private var busy = false
    @AppStorage("VexSign.ecosystem.certificateMonitoring") private var monitoring = false
    var body: some View {
        List {
            Section {
                Button(.localized("Validate with System OCSP")) { Task { await refresh(online: true) } }.disabled(busy)
                Text(.localized("Private keys stay on this device. OCSP sends certificate identifiers to responders, never the P12 or its password. An unavailable response is Unknown, never Good.")).font(.caption)
                Toggle(.localized("Daily Health Monitoring"), isOn: $monitoring)
                    .onChange(of: monitoring) { _, enabled in
                        Task { await certificates.setMonitoringEnabled(enabled) }
                    }
            }
            if busy { ProgressView(.localized("Inspecting certificates…")) }
            ForEach(health) { cert in
                Section(cert.name) {
                    HStack {
                        Text(.localized("Certificate Health")); Spacer()
                        Text("\(cert.score)/100").bold().foregroundStyle(cert.score >= 80 ? .green : cert.score >= 40 ? .yellow : .red)
                    }
                    let assessment = cert.assessment()
                    row(.localized("Status"), assessment.status.title)
                    Text(assessment.explanation).font(.caption).foregroundStyle(.secondary)
                    row(.localized("OCSP"), cert.revocation.rawValue.capitalized)
                    row(.localized("Team ID"), cert.teamID); row(.localized("Team Name"), cert.teamName)
                    row(.localized("Profile Expiry"), cert.expires.formatted())
                    row(.localized("Certificate Expiry"), cert.certificateExpires?.formatted() ?? .localized("Unavailable"))
                    if let certificateExpires = cert.certificateExpires {
                        row(.localized("Certificate Days Remaining"), String(Int(floor(certificateExpires.timeIntervalSinceNow / 86_400))))
                    }
                    row(.localized("Days Remaining"), String(cert.daysRemaining))
                    row(.localized("Devices"), cert.allDevices ? .localized("All devices (enterprise profile)") : String(cert.deviceCount))
                    row(.localized("Bundle Scope"), cert.applicationIdentifier)
                    row(.localized("Bundle Count"), cert.applicationIdentifier.contains("*") ? .localized("Wildcard (not enumerable)") : .localized("1 profile scope"))
                    row(.localized("Push Entitlement"), cert.push ? .localized("Present") : .localized("Absent"))
                    row(.localized("JIT"), cert.debugEntitlement ? .localized("Debug entitlement present; runtime support not guaranteed") : .localized("Not established by profile"))
                    Text(cert.detail).font(.caption).foregroundStyle(.secondary)
                    ShareLink(
                        item: cert.redactedHealthCard,
                        subject: Text(.localized("VexSign certificate health card")),
                        message: Text(.localized("Redacted certificate health summary"))
                    ) {
                        Label(.localized("Share Redacted Health Card"), systemImage: "square.and.arrow.up")
                    }
                    NavigationLink(.localized("Entitlements")) { ScrollView { Text(cert.entitlements).font(Theme.Typography.identifier).textSelection(.enabled).padding() }.navigationTitle(.localized("Entitlements")) }
                    NavigationLink(.localized("Provision Payload")) { ScrollView { Text(cert.provision).font(Theme.Typography.identifier).textSelection(.enabled).padding() }.navigationTitle(.localized("Provision")) }
                }
            }
            ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red) }
        }.navigationTitle(.localized("Certificate Health"))
            .task { await refresh(online: false) }
    }
    private func refresh(online: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let report = try await certificates.inspectAll(online: online)
            try Task.checkCancellation()
            health = report.certificates
            errors = report.errors
        } catch is CancellationError { return }
        catch { errors = [error.localizedDescription] }
    }
    private func row(_ title: String, _ value: String) -> some View { HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) } }
}
