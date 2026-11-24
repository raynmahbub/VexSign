//
//  JITSettingsView.swift
//  VexSign — JIT & Pairing Tools
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import NimbleViews
import NimbleExtensions

struct JITSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var pairingState: DevicePairingState = PairingBridge.inspectPairingRecord()
    @State private var isCheckingDiagnostics = false
    @State private var socketReachable: Bool?
    @State private var isLocalDevVPNAvailable = false
    @State private var diagnosticSummary: String?

    private var hasUsablePairing: Bool {
        pairingState.isUsable
    }

    private var trollStoreDetected: Bool {
        TrollStoreHandoff.installedByTrollStore()
    }

    private var embeddedRuntimeAvailable: Bool {
        EmbeddedContainerRuntime.isAvailable
    }

    var body: some View {
        NBList(.localized("JIT & On-Device Pairing")) {
            headerSection

            pairingStatusSection

            jitCapabilitySection

            diagnosticsSection

            urlSchemeSection
        }
        .onAppear {
            clearLegacyFakePreferences()
            refreshLocalState()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshLocalState()
            }
        }
    }

    private var headerSection: some View {
        NBSection(.localized("Pairing & JIT Availability")) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "bolt.badge.automatic.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.teal)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(.localized("On-Device Pairing & Launch Tools"))
                        .font(.headline)
                    Text(.localized("Review pairing formats and OS limits, inspect the local endpoint, and open the guided read-only device check. File and socket checks do not prove installation readiness."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var pairingStatusSection: some View {
        NBSection(.localized("Pairing File")) {
            HStack(spacing: 12) {
                Image(systemName: hasUsablePairing ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(hasUsablePairing ? Color.green : Color.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pairingState.title)
                        .font(.subheadline.weight(.semibold))
                    Text(pairingState.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let udid = pairingState.udid {
                        Text(String.localized("Device UDID: …%@", arguments: String(udid.suffix(8))))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                NavigationLink {
                    NBList(.localized("Device bootstrap")) { TunnelView() }
                } label: {
                    Label(.localized("Review setup"), systemImage: "cable.connector")
                        .font(.caption.weight(.bold))
                }
            }
            .padding(.vertical, 2)

            NavigationLink(destination: InstallationView()) {
                Label(.localized("Installation Engine & Tunnel"), systemImage: "arrow.down.app")
            }

            if isLocalDevVPNAvailable {
                Button {
                    UIApplication.open("localdevvpn://")
                } label: {
                    Label(.localized("Open LocalDevVPN"), systemImage: "link")
                }
            } else {
                Button {
                    UIApplication.open("https://apps.apple.com/us/app/localdevvpn/id6755608044")
                } label: {
                    Label(.localized("Get LocalDevVPN"), systemImage: "arrow.down.app")
                }
            }
        } footer: {
            Text(.localized("Pairing records are format-checked and protected by the shared bootstrap flow. File validity and a reachable endpoint are not device trust. Open setup for explicit replacement, export and a fresh read-only authorization query."))
        }
    }

    private var jitCapabilitySection: some View {
        NBSection(.localized("JIT Support Status")) {
            LabeledContent(
                .localized("In-App Debugserver JIT"),
                value: String.localized("Not supported in this build")
            )
            LabeledContent(
                .localized("TrollStore Install Detected"),
                value: trollStoreDetected ? String.localized("Yes") : String.localized("No")
            )
            LabeledContent(
                .localized("Embedded LiveContainer"),
                value: embeddedRuntimeAvailable ? String.localized("Available") : String.localized("Not Loaded")
            )
        } footer: {
            Text(.localized("Stock sandboxed VexSign does not run an in-app debugserver JIT injector. For TrollStore installs, enable JIT directly in TrollStore. For standard sideloads, attach JIT via an external debugger or SideStore/LiveContainer workflow."))
        }
    }

    private var diagnosticsSection: some View {
        NBSection(.localized("Local Pairing Diagnostics")) {
            Button {
                runPairingDiagnostics()
            } label: {
                HStack {
                    if isCheckingDiagnostics {
                        ProgressView().scaleEffect(0.9).padding(.trailing, 6)
                    } else {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundStyle(Color.teal)
                    }
                    Text(isCheckingDiagnostics ? String.localized("Checking pairing endpoint…") : String.localized("Check pairing endpoint"))
                        .font(.subheadline.weight(.medium))
                }
            }
            .disabled(isCheckingDiagnostics)

            if let socketReachable {
                LabeledContent(
                    .localized("Endpoint reachability"),
                    value: socketReachable ? String.localized("Reachable — not authorized") : String.localized("Not reachable")
                )
            }

            if let diagnosticSummary {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Color.orange)
                    Text(diagnosticSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } footer: {
            Text(.localized("Inspects the same pairing record and performs only a bounded endpoint probe through PairingBridge. It does not establish VPN ownership, device authorization, service availability or installation support."))
        }
    }

    private var urlSchemeSection: some View {
        NBSection(.localized("Working URL Schemes")) {
            _copyableSchemeRow(
                title: .localized("Launch Installed App by Bundle ID"),
                url: "vexsign://launch?bundleId=com.example.app"
            )
            _copyableSchemeRow(
                title: .localized("Download & Install IPA"),
                url: "vexsign://install?url=https://site.com/app.ipa"
            )
        } footer: {
            Text(.localized("Tap either scheme to copy it. Launching external apps via vexsign://launch uses iOS app-launch permissions and cannot force-attach JIT on stock iOS."))
        }
    }

    private func _copyableSchemeRow(title: LocalizedStringKey, url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
            Button {
                UIPasteboard.general.string = url
                NBHaptic.selection()
                Toast.success(.localized("Link copied"), systemImage: "doc.on.clipboard")
            } label: {
                HStack {
                    Text(verbatim: url)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(Color.userTint)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func runPairingDiagnostics() {
        isCheckingDiagnostics = true
        diagnosticSummary = nil
        refreshLocalState()

        Task {
            let connected = await Task.detached(priority: .userInitiated) {
                PairingBridge.isSocketConnected()
            }.value

            isCheckingDiagnostics = false
            socketReachable = connected

            switch pairingState {
            case .absent, .unreadable, .oversized, .incomplete:
                diagnosticSummary = pairingState.detail
            case .readable, .validated:
                if connected {
                    diagnosticSummary = .localized("The pairing record has a recognized structure and the endpoint answered. No authorized device session was opened; installation remains gated.")
                } else {
                    diagnosticSummary = .localized("The pairing record is readable, but this endpoint probe did not establish reachability. Review the OS route and manually activated VPN in bootstrap; do not assume the record was revoked.")
                }
            }
        }
    }

    private func refreshLocalState() {
        pairingState = PairingBridge.inspectPairingRecord()
        if let url = URL(string: "localdevvpn://") {
            isLocalDevVPNAvailable = UIApplication.shared.canOpenURL(url)
        } else {
            isLocalDevVPNAvailable = false
        }
    }

    private func clearLegacyFakePreferences() {
        UserDefaults.standard.removeObject(forKey: "VexSign.jit.autoEnable")
        UserDefaults.standard.removeObject(forKey: "VexSign.jit.serverPort")
    }
}
