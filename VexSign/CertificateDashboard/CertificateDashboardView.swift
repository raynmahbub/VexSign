import SwiftUI
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
                let health = try await CertificateInspector.inspect(id: id, name: cert.nickname ?? "Certificate", p12: p12,
                                                                    password: try cert.requireSigningPassword(), profile: profile, online: online)
                next.append(health)
            } catch { errors.append("\(cert.nickname ?? "Certificate"): \(error.localizedDescription)") }
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
                Button("Validate with System OCSP") { Task { await model.refresh(online: true) } }.disabled(model.busy)
                Text("Private keys stay on this device. OCSP sends certificate identifiers to responders, never the P12 or its password. An unavailable response is Unknown, never Good.").font(.caption)
                Toggle("Daily Health Monitoring", isOn: $monitoring)
                    .onChange(of: monitoring) { enabled in
                        if enabled { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); EcosystemMaintenance.schedule() } }
                    }
            }
            if model.busy { ProgressView("Inspecting certificates…") }
            ForEach(model.certificates) { cert in
                Section(cert.name) {
                    HStack {
                        Text("Certificate Health"); Spacer()
                        Text("\(cert.score)/100").bold().foregroundStyle(cert.score >= 80 ? .green : cert.score >= 40 ? .yellow : .red)
                    }
                    row("OCSP", cert.revocation.rawValue.capitalized)
                    row("Team ID", cert.teamID); row("Team Name", cert.teamName)
                    row("Profile Expiry", cert.expires.formatted())
                    row("Certificate Expiry", cert.certificateExpires?.formatted() ?? "Unavailable")
                    if let certificateExpires = cert.certificateExpires {
                        row("Certificate Days Remaining", String(Int(floor(certificateExpires.timeIntervalSinceNow / 86_400))))
                    }
                    row("Days Remaining", String(cert.daysRemaining))
                    row("Devices", cert.allDevices ? "All devices (enterprise profile)" : String(cert.deviceCount))
                    row("Bundle Scope", cert.applicationIdentifier)
                    row("Bundle Count", cert.applicationIdentifier.contains("*") ? "Wildcard (not enumerable)" : "1 profile scope")
                    row("Push Entitlement", cert.push ? "Present" : "Absent")
                    row("JIT", cert.debugEntitlement ? "Debug entitlement present; runtime support not guaranteed" : "Not established by profile")
                    Text(cert.detail).font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Entitlements") { ScrollView { Text(cert.entitlements).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }.navigationTitle("Entitlements") }
                    NavigationLink("Provision Payload") { ScrollView { Text(cert.provision).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }.navigationTitle("Provision") }
                }
            }
            ForEach(model.errors, id: \.self) { Text($0).foregroundStyle(.red) }
        }.navigationTitle("Certificate Health")
            .task { await model.refresh(online: false) }
    }
    private func row(_ title: String, _ value: String) -> some View { HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) } }
}
