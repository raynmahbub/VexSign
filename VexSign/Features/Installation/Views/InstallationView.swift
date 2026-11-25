//
//  InstallationView.swift
//  VexSign
//
//  Created by VexSign Contributors on 3.06.2025.
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

    private var _selectedInstallMethod: InstallMethodKind {
        switch _modeManager.methodChoice {
        case .embeddedContainer: return .liveContainer
        case .direct: return _installationMethod == 1 ? .idevice : .server
        }
    }

    private var _selectedMethodReadiness: InstallReadiness {
        InstallPreflight.readiness(for: _selectedInstallMethod, _preflight)
    }

    // MARK: Body
    var body: some View {
        NBList(.localized("Installation")) {
            Section {
                Picker(.localized("Signing identity"), systemImage: "person.crop.circle.badge.checkmark", selection: Binding(
                    get: { _modeManager.identityChoice },
                    set: { _modeManager.selectIdentity($0) }
                )) {
                    Text(.localized("Imported .p12 + profile")).tag(SigningIdentityChoice.importedCertificate)
                    Text(.localized("Apple Account")).tag(SigningIdentityChoice.appleAccount)
                }
                Text(.localized("This chooses who signs. It never changes the installation method below."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(.localized("1. Signing identity"))
            }

            Section {
                Picker(.localized("Installation method"), systemImage: "arrow.triangle.branch", selection: Binding(
                    get: { _modeManager.methodChoice },
                    set: { _modeManager.selectMethod($0) }
                )) {
                    Text(.localized("Direct installation")).tag(InstallationMethodChoice.direct)
                    Text(.localized("Embedded container")).tag(InstallationMethodChoice.embeddedContainer)
                }

                HStack {
                    Text(.localized("Device readiness"))
                    Spacer()
                    Text(verbatim: InstallPreflight.summary(for: _selectedMethodReadiness))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(_preflightColor(_selectedMethodReadiness))
                }
                Text(verbatim: InstallPreflight.detail(for: InstallMethodReport(
                    method: _selectedInstallMethod, readiness: _selectedMethodReadiness
                )))
                .font(.caption).foregroundStyle(.secondary)

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
                Text(.localized("2. Installation method"))
            } footer: {
                Text(.localized("Direct uses the transport chosen below. Embedded container needs the combined host runtime; if it is not ready the route fails closed instead of falling back. An Apple Account never selects it for you."))
            }

            Section {
                Picker(.localized("Direct transport"), systemImage: "arrow.down.app", selection: Binding(
                    get: {
                        _installationMethod == 0 || _installationMethod == 1
                            ? _installationMethod : _modeManager.preferredDirectMethod
                    },
                    set: { _modeManager.selectDirectMethod($0) }
                )) {
                    Text(.localized("Server")).tag(0)
                    Text(.localized("idevice")).tag(1)
                }

                if _modeManager.methodChoice == .embeddedContainer {
                    Text(.localized("This refines Direct installation only. Choosing a transport switches the installation method back to Direct; it does not change the signing identity."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(.localized("Server: serves a signed IPA through local HTTPS and itms-services; delivery is not installation confirmation.\n\nIDevice: paired installation is blocked in this build until the native inventory ownership contract and exact installed-version read-back are accepted. A VPN, pairing file or successful identity query does not remove this gate. Export remains available."))
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
                EmbeddedRuntimeAvailabilityNote()
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
                "Paired installation is not enabled merely by importing a pairing file or activating a VPN. This build requires an accepted same-device inventory bridge and exact installed-version read-back before native submission is allowed. Review the bootstrap limitations or export the signed IPA."
            ))
        }
        .onAppear(perform: _refreshPreflight)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { _refreshPreflight() }
        }
        .appAnimation(.default, value: _modeManager.methodChoice)
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
