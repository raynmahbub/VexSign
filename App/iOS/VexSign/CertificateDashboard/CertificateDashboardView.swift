import SwiftUI
import NimbleExtensions
import UserNotifications

@MainActor
final class CertificateDashboardViewModel: ObservableObject {
    @Published private(set) var certificates: [CertificateHealth] = []
    @Published private(set) var busy = false
    @Published var errors: [String] = []
    func refresh(online: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        errors = []
        var next: [CertificateHealth] = []
        // Keep NSManagedObjects on the main actor; only immutable file URLs cross over.
        for cert in Storage.shared.getAllCertificates() {
            if Task.isCancelled { break }
            guard let id = cert.uuid, let p12 = Storage.shared.getFile(.certificate, from: cert),
                  let profile = Storage.shared.getFile(.provision, from: cert) else { continue }
            do {
                let health = try await CertificateInspector.inspect(id: id, name: cert.nickname ?? .localized("Certificate"), p12: p12,
                                                                    password: try cert.requireSigningPassword(), profile: profile, online: online)
                next.append(health)
            } catch { errors.append("\(cert.nickname ?? .localized("Certificate")): \(error.localizedDescription)") }
        }
        certificates = next
    }
}

struct CertificateDashboardView: View {
    @StateObject private var model = CertificateDashboardViewModel()
    @AppStorage("VexSign.ecosystem.certificateMonitoring") private var monitoring = false
    var body: some View {
        List {
            Section {
                Button(.localized("Validate with System OCSP")) { Task { await model.refresh(online: true) } }.disabled(model.busy)
                Text(.localized("Private keys stay on this device. OCSP sends certificate identifiers to responders, never the P12 or its password. An unavailable response is Unknown, never Good.")).font(.caption)
                Toggle(.localized("Daily Health Monitoring"), isOn: $monitoring)
                    .onChange(of: monitoring) { _, enabled in
                        if enabled { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); EcosystemMaintenance.schedule() } }
                    }
            }
            if model.busy { ProgressView(.localized("Inspecting certificates…")) }
            ForEach(model.certificates) { cert in
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
                    NavigationLink(.localized("Entitlements")) { ScrollView { Text(cert.entitlements).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }.navigationTitle(.localized("Entitlements")) }
                    NavigationLink(.localized("Provision Payload")) { ScrollView { Text(cert.provision).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }.navigationTitle(.localized("Provision")) }
                }
            }
            ForEach(model.errors, id: \.self) { Text($0).foregroundStyle(.red) }
        }.navigationTitle(.localized("Certificate Health"))
            .task { await model.refresh(online: false) }
    }
    private func row(_ title: String, _ value: String) -> some View { HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) } }
}
