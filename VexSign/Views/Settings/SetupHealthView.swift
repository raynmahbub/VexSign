import SwiftUI
import NimbleViews
import NimbleExtensions
import IDeviceSwift
import UIKit

// Configuration evidence only: successful signing and installation still need a device pass.
struct SetupHealthView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("vexsign.selectedCert") private var selectedCertificateIndex = 0
    @AppStorage(BackgroundAutomationPreferences.enabledKey) private var automationEnabled = false
    @AppStorage(GameMode.enabledKey) private var gameMode = false
    @ObservedObject private var history = AutomationHistoryStore.shared
    @FetchRequest(
        entity: CertificatePair.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
    ) private var certificates: FetchedResults<CertificatePair>
    @AppStorage("VexSign.installationMethod") private var installationMethod = 0
    @State private var checkedAt = Date()
    @State private var inputs = InstallPreflightInputs()

    private var certificate: CertificatePair? {
        guard certificates.indices.contains(selectedCertificateIndex) else { return nil }
        return certificates[selectedCertificateIndex]
    }

    var body: some View {
        NBList(.localized("Setup Health")) {
            attentionSection
            Section {
                NavigationLink(destination: CompanionSetupDiagnosticsView()) {
                    Label(.localized("Companion Setup Diagnostics"), systemImage: "stethoscope")
                }
            }
            Section {
                NavigationLink(destination: CertificatesView()) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(.localized("Signing Certificate"), systemImage: "checkmark.seal")
                            .font(.headline)
                        if let certificate {
                            Text(certificate.nickname ?? .localized("Selected certificate"))
                            if let expiry = certificate.expiration {
                                Text(expiry <= Date() ? .localized("Expired — choose another certificate") : .localized("Expiry recorded; revocation not checked here"))
                                    .foregroundStyle(expiry <= Date() ? Color.red : Color.secondary)
                                Text(expiry, style: .date).font(.caption)
                            } else {
                                Text(.localized("Expiry unknown — review certificate details"))
                            }
                        } else {
                            Text(.localized("No Certificate Configured"))
                        }
                    }
                }
                NavigationLink(destination: CertificateExpirySettingsView()) {
                    Label(.localized("Expiry Reminders"), systemImage: "bell.badge")
                }
            } header: {
                Text(.localized("Certificates"))
            } footer: {
                Text(.localized("A stored certificate is not proof of signing readiness. Profile scope, entitlements, device eligibility and revocation require separate checks."))
            }

            Section {
                ForEach(InstallPreflight.report(inputs)) { report in
                    NavigationLink(destination: InstallationView()) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: report.method.title).font(.headline)
                            Text(verbatim: InstallPreflight.summary(for: report.readiness))
                            Text(verbatim: InstallPreflight.detail(for: report))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text(.localized("Install methods"))
            } footer: {
                Text(.localized("These checks detect local prerequisites only. HTTPS trust, VPN connectivity and actual installation acceptance are not verified here."))
            }

            Section {
                NavigationLink(destination: AutomationView()) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(.localized("Background Automation"), systemImage: "bolt.badge.clock.fill")
                            .font(.headline)
                        Text(automationEnabled ? .localized("Enabled") : .localized("Disabled"))
                        if gameMode {
                            Text(.localized("Paused by Game Mode")).foregroundStyle(.orange)
                        }
                        if let last = history.entries.first {
                            Text(.localized("Latest recorded attempt"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(last.date, style: .relative).font(.caption)
                        } else {
                            Text(.localized("No automation runs yet.")).font(.caption)
                        }
                    }
                }
                NavigationLink(destination: RefreshAndDownloadsSettingsView()) {
                    Label(.localized("Refresh & Background Sync"), systemImage: "arrow.clockwise.icloud")
                }
            } header: {
                Text(.localized("Automation"))
            } footer: {
                Text(.localized("iOS schedules background work opportunistically. Open Automation for outcomes and manual refresh; installations may require confirmation."))
            }
        }
        .onAppear(perform: refresh)
        .nbOnChange(of: scenePhase) { phase in
            if phase == .active { refresh() }
        }
    }

    private enum AttentionTarget {
        case certificates, installation, gameMode, automation
    }

    private struct AttentionItem: Identifiable {
        let id: String
        let title: String
        let detail: String
        let target: AttentionTarget
    }

    private var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        if let certificate {
            if let expiry = certificate.expiration {
                if expiry <= checkedAt {
                    items.append(.init(id: "expired", title: .localized("Certificate expired"), detail: .localized("Choose a valid signing identity before signing another app."), target: .certificates))
                } else if expiry.timeIntervalSince(checkedAt) <= 14 * 24 * 60 * 60 {
                    items.append(.init(id: "expiring", title: .localized("Certificate expires within 14 days"), detail: .localized("Prepare a replacement certificate and provisioning profile. VexSign cannot renew these automatically."), target: .certificates))
                }
            } else {
                items.append(.init(id: "unknownExpiry", title: .localized("Certificate expiry is unknown"), detail: .localized("Review the selected identity and provisioning profile before signing."), target: .certificates))
            }
        } else {
            items.append(.init(id: "missingCertificate", title: .localized("No Certificate Configured"), detail: .localized("Import your certificate and provisioning profile to enable signing."), target: .certificates))
        }

        let readiness = InstallMethodKind.selected(forStoredValue: installationMethod)
            .map { InstallPreflight.readiness(for: $0, inputs) }
            ?? .missing(.localized("Unknown installation method. Choose OTA, pairing/IDevice or embedded guest import in Settings."))
        switch readiness {
        case .ready: break
        case .missing(let detail), .unknown(let detail), .unavailable(let detail):
            items.append(.init(id: "installation", title: .localized("Selected install method needs setup"), detail: detail, target: .installation))
        }
        if automationEnabled && gameMode {
            items.append(.init(id: "gameMode", title: .localized("Paused by Game Mode"), detail: .localized("Turn off Game Mode when you want scheduled refresh and signing to resume."), target: .gameMode))
        }
        // Ignore newer skipped attempts: they do not erase the last actual run's failures.
        if let lastRun = history.entries.first(where: { $0.outcome == "completed" || $0.outcome == "partialFailure" }), (lastRun.failed ?? 0) > 0 {
            items.append(.init(id: "failures", title: .localized("Latest automation run had failures"), detail: .localized("Open automation history to review counts, then inspect Activity Logs for details."), target: .automation))
        }
        return items
    }

    private var attentionSection: some View {
        Section {
            if attentionItems.isEmpty {
                Label(.localized("No configuration warnings detected"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(attentionItems) { item in
                NavigationLink {
                    attentionDestination(item.target)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(item.title, systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text(.localized("Needs Attention"))
        } footer: {
            Text(.localized("Warnings cover local configuration only, not a full device or signing verification. Optional features that are off are not treated as failures."))
        }
    }

    @ViewBuilder
    private func attentionDestination(_ target: AttentionTarget) -> some View {
        switch target {
        case .certificates: CertificatesView()
        case .installation: InstallationView()
        case .gameMode: GameModeView()
        case .automation: AutomationView()
        }
    }

    private func refresh() {
        checkedAt = Date()
        inputs = InstallPreflightInputs(
            hasServerCertificate: LocalTLSIdentity.current() != nil,
            hasPairingFile: FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()),
            trollStoreDetected: ["trollstore://"].contains { scheme in
                guard let url = URL(string: scheme) else { return false }
                return UIApplication.shared.canOpenURL(url)
            },
            hasTrustedServerCertificate: LocalTLSIdentity.isSystemTrusted(),
            hasEmbeddedRuntime: EmbeddedContainerRuntime.isAvailable
        )
    }
}
