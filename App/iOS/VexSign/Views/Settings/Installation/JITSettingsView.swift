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
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.teal)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(.localized("On-Device Pairing & Launch Tools"))
                        .font(.headline)
                    Text(.localized("Manage your lockdownd pairing file, verify the local heartbeat socket, and copy working vexsign:// deep links."))
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

                Button {
                    importPairingFile()
                } label: {
                    Text(hasUsablePairing ? String.localized("Replace") : String.localized("Import"))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.userTint, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)

            NavigationLink(destination: InstallationView()) {
                Label(.localized("Installation Engine & Tunnel"), systemImage: "arrow.down.app")
            }

            if isLocalDevVPNAvailable {
                Button {
                    UIApplication.open("localdevvpn://enable?scheme=vexsign")
                } label: {
                    Label(.localized("Connect LocalDevVPN"), systemImage: "link")
                }
            } else {
                Button {
                    UIApplication.open("https://apps.apple.com/us/app/localdevvpn/id6755608044")
                } label: {
                    Label(.localized("Get LocalDevVPN"), systemImage: "arrow.down.app")
                }
            }
        } footer: {
            Text(.localized("A pairing file lets VexSign's embedded idevice transport talk to lockdownd when a loopback VPN is active. Importing a file validates its HostID and stores it atomically."))
        }
    }

    private var jitCapabilitySection: some View {
        NBSection(.localized("JIT Support Status")) {
            LabeledContent(
                .localized("In-App Debugserver JIT"),
                value: String.localized("Not Implemented")
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
                    Text(isCheckingDiagnostics ? String.localized("Checking Pairing & Heartbeat…") : String.localized("Check Pairing & Heartbeat Socket"))
                        .font(.subheadline.weight(.medium))
                }
            }
            .disabled(isCheckingDiagnostics)

            if let socketReachable {
                LabeledContent(
                    .localized("Heartbeat Socket"),
                    value: socketReachable ? String.localized("Connected") : String.localized("Not Connected")
                )
            }

            if let diagnosticSummary {
                HStack(spacing: 8) {
                    Image(systemName: (socketReachable == true && hasUsablePairing) ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle((socketReachable == true && hasUsablePairing) ? Color.green : Color.orange)
                    Text(diagnosticSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } footer: {
            Text(.localized("Inspects the on-disk pairing record and probes the real lockdownd heartbeat TCP socket managed by PairingBridge."))
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

    private func importPairingFile() {
        DocumentPicker.open([.xmlPropertyList, .plist, .mobiledevicepairing], folder: .pairing) { urls in
            guard let url = urls.first else { return }
            do {
                try CertificateManagementService.installPairingFile(from: url)
                refreshLocalState()
                Toast.success(.localized("Pairing file imported"), systemImage: "checkmark.circle.fill")
            } catch {
                Toast.error(error.localizedDescription, duration: .long)
            }
        }
    }

    private func runPairingDiagnostics() {
        isCheckingDiagnostics = true
        diagnosticSummary = nil
        refreshLocalState()
        PairingBridge.restartHeartbeat()

        Task {
            let connected = await Task.detached(priority: .userInitiated) {
                PairingBridge.isSocketConnected()
            }.value

            isCheckingDiagnostics = false
            socketReachable = connected

            switch pairingState {
            case .absent, .unreadable, .oversized, .incomplete:
                diagnosticSummary = pairingState.detail
            case .readable:
                if connected {
                    diagnosticSummary = .localized("Pairing record is valid and the local heartbeat socket is reachable for idevice installation.")
                } else {
                    diagnosticSummary = .localized("Pairing record is readable, but the heartbeat socket is not connected. Enable your loopback VPN (such as LocalDevVPN) on Wi-Fi or Airplane mode and retry.")
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
