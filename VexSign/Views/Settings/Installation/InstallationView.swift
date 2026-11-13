//
//  InstallationView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 3.06.2025.
//

import SwiftUI
import UIKit
import NimbleViews
import NimbleExtensions

// MARK: - View
struct InstallationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("VexSign.installationMethod") private var _installationMethod: Int = 0
    @StateObject private var _modeManager = SigningModeManager.shared
    @State private var _showMethodChangedAlert = false
    @State private var _preflight = InstallPreflightInputs()

    private var _routeResult: Result<InstallationPipeline, Error> {
        do { return .success(try _modeManager.pipeline()) }
        catch { return .failure(error) }
    }

    private var _pipeline: InstallationPipeline? {
        guard case .success(let pipeline) = _routeResult else { return nil }
        return pipeline
    }

    private var _routingError: Error? {
        guard case .failure(let error) = _routeResult else { return nil }
        return error
    }

    // MARK: Body
    var body: some View {
        NBList(.localized("Installation")) {
            Section {
                Picker(.localized("App Routing"), systemImage: "arrow.triangle.branch", selection: Binding(
                    get: { _modeManager.preference },
                    set: { _modeManager.selectPreference($0) }
                )) {
                    ForEach(SigningModePreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }

                if let pipeline = _pipeline {
                    LabeledContent(.localized("Resolved route")) {
                        Text(verbatim: "\(pipeline.mode.title) · \(pipeline.installMethod.title)")
                            .multilineTextAlignment(.trailing)
                    }
                } else if let error = _routingError {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            } header: {
                Text(.localized("Dual-mode app routing"))
            } footer: {
                Text(.localized("Automatic uses a usable long-lived or enterprise certificate for direct signing. In the combined host, a missing, expired, revoked or short-profile certificate selects the container instead. Standalone builds retain their direct OTA/IDevice path for already signed IPAs. Explicit modes never silently fall back."))
            }

            Section {
                Picker(.localized("Direct Installation Type"), systemImage: "arrow.down.app", selection: Binding(
                    get: {
                        _installationMethod == 0 || _installationMethod == 1
                            ? _installationMethod : _modeManager.preferredDirectMethod
                    },
                    set: { _modeManager.selectDirectMethod($0) }
                )) {
                    Text(.localized("Server")).tag(0)
                    Text(.localized("idevice")).tag(1)
                }

                if _modeManager.preference == .containerized {
                    Text(.localized("Changing this selector chooses Direct Paid / Certificate routing. Your current container selection remains unchanged until then."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(.localized("Server (Recommended): Uses a locally hosted server and itms-services:// to install applications.\n\nIDevice (advanced): Uses a VPN and a pairing file. Writes to AFC and manually calls installd, while monitoring install progress by using a callback. It does not require a local HTTPS certificate or an externally hosted server."))
            }

            Section {
                ForEach(InstallPreflight.report(_preflight)) { report in
                    _preflightRow(report)
                }
            } header: {
                Text(.localized("Install methods"))
            } footer: {
                Text(.localized("Ready means local prerequisites are present, not that an app has been installed. Export and TrollStore remain separate actions. A prepared guest is not an iOS device installation."))
            }

            if _pipeline?.installMethod == .server {
                ServerView()
                Section {
                    NavigationLink(destination: AntiRevokeView()) {
                        Label(.localized("Anti-Revoke"), systemImage: "shield.lefthalf.filled")
                    }
                }
            } else if _pipeline?.installMethod == .idevice {
                TunnelView()
            } else if _pipeline == .containerized, EmbeddedContainerRuntime.isAvailable {
                EmbeddedContainerControls()
            }

            Section {
                NavigationLink(.localized("OTA certificate and trust setup")) {
                    NBList(.localized("Server & SSL")) { ServerView() }
                }
                NavigationLink(.localized("Pairing file and VPN setup")) {
                    NBList(.localized("Tunnel")) { TunnelView() }
                }
                if !EmbeddedContainerRuntime.isAvailable {
                    Link(.localized("Combined host setup and limitations"), destination: URL(string: "https://github.com/raynmahbub/VexSign/blob/main/EmbeddedContainer/README.md")!)
                    Link(.localized("Experimental combined host builds"), destination: URL(string: "https://github.com/raynmahbub/VexSign/actions/workflows/embedded-container.yml")!)
                }
                Button(.localized("Recheck installation prerequisites"), action: _refreshPreflight)
            }
        }
        .onChange(of: _installationMethod) { _, newValue in
            NBHaptic.selection()
            guard newValue == 1 else { return }
            _showMethodChangedAlert = true
        }
        .alert(.localized("Advanced Installation Method"), isPresented: $_showMethodChangedAlert) {
            Button(.localized("Switch Back"), role: .destructive) {
                _modeManager.selectDirectMethod(0)
            }
            Button(.localized("OK"), role: .cancel) {}
        } message: {
            Text(.localized(
                "This installation method is intended for advanced users only!\n\nIt requires a VPN and a pairing file from a PC.\n\nWe recommend using the server installation method unless pairing and VPN are configured."
            ))
        }
        .onAppear(perform: _refreshPreflight)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { _refreshPreflight() }
        }
        .animation(.default, value: _modeManager.preference)
    }

    // MARK: Preflight

    private func _refreshPreflight() {
        _preflight = InstallPreflightInputs(
            hasServerCertificate: LocalTLSIdentity.current() != nil,
            pairing: PairingBridge.inspectPairingRecord(),
            trollStoreDetected: TrollStoreHandoff.installedByTrollStore(),
            hasTrustedServerCertificate: LocalTLSIdentity.isSystemTrusted(),
            hasEmbeddedRuntime: EmbeddedContainerRuntime.isAvailable
        )
    }

    @ViewBuilder
    private func _preflightRow(_ report: InstallMethodReport) -> some View {
        let isSelected = report.method == _pipeline?.installMethod

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(report.method.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(Text(.localized("Selected")))
                }

                Spacer(minLength: 6)

                Text(verbatim: InstallPreflight.summary(for: report.readiness))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(_preflightColor(report.readiness))
            }

            Text(verbatim: InstallPreflight.detail(for: report))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func _preflightColor(_ readiness: InstallReadiness) -> Color {
        switch readiness {
        case .ready: return .green
        case .missing: return .orange
        case .unavailable: return .secondary
        case .unknown: return .secondary
        }
    }
}
