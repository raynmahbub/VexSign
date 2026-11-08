//
//  InstallationView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 3.06.2025.
//

import SwiftUI
import UIKit
import IDeviceSwift
import NimbleViews
import NimbleExtensions

// MARK: - View
struct InstallationView: View {
    @Environment(\.scenePhase) private var scenePhase
	@AppStorage("VexSign.installationMethod") private var _installationMethod: Int = 0
	@State private var _showMethodChangedAlert = false
	@State private var _preflight = InstallPreflightInputs()

	private let _installationMethods: [String] = [
		.localized("Server"),
		.localized("idevice"),
		.localized("Embedded LiveContainer guest")
	]
	
	// MARK: Body
    var body: some View {
		NBList(.localized("Installation")) {
			Section {
				Picker(.localized("Installation Type"), systemImage: "arrow.down.app", selection: $_installationMethod) {
					ForEach(_installationMethods.indices, id: \.description) { index in
						Text(_installationMethods[index]).tag(index)
					}
				}
			} footer: {
				Text(.localized("Server (Recommended):\nUses a locally hosted server and itms-services:// to install applications.\n\nIDevice (advanced):\nUses a VPN and a pairing file. Writes to AFC and manually calls installd, while monitoring install progress by using a callback\nAdvantage: It is very reliable, does not require a local HTTPS certificate or an externally hosted server. It works similarly to a computer."))
			}

			// every route, and the one thing each of them needs — checked before the
			// install rather than reported afterwards as a socket error.
			Section {
				ForEach(InstallPreflight.report(_preflight)) { report in
					_preflightRow(report)
				}
			} header: {
				Text(.localized("Install methods"))
			} footer: {
				Text(.localized("The Installation Type picker selects OTA, pairing/IDevice or embedded guest import. Export and TrollStore are separate actions. Ready means local prerequisites are present, not that an app has been installed."))
			}
			
			if _installationMethod == 0 {
				ServerView()

				Section {
					NavigationLink(destination: AntiRevokeView()) {
						Label(.localized("Anti-Revoke"), systemImage: "shield.lefthalf.filled")
					}
				}
			} else if _installationMethod == 1 {
				TunnelView()
			} else if _installationMethod == 2 {
				if EmbeddedContainerRuntime.isAvailable {
					EmbeddedContainerControls()
				}
			}
			Section {
				NavigationLink(.localized("OTA certificate and trust setup")) { NBList(.localized("Server & SSL")) { ServerView() } }
				NavigationLink(.localized("Pairing file and VPN setup")) { NBList(.localized("Tunnel")) { TunnelView() } }
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
				_installationMethod = 0
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
		.onChange(of: _installationMethod) { _, _ in _refreshPreflight() }
		.animation(.default, value: _installationMethod)
    }

	// MARK: Preflight

	private func _refreshPreflight() {
		_preflight = InstallPreflightInputs(
			hasServerCertificate: LocalTLSIdentity.current() != nil,
			hasPairingFile: FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()),
			trollStoreDetected: _trollStoreDetected(),
            hasTrustedServerCertificate: LocalTLSIdentity.isSystemTrusted(),
			hasEmbeddedRuntime: EmbeddedContainerRuntime.isAvailable
		)
	}

	/// TrollStore's own marker beside the app bundle. Apple's Magnifier scheme
	/// answers on stock iOS, so a scheme probe alone would report TrollStore
	/// everywhere; see `TrollStoreHandoff`.
	private func _trollStoreDetected() -> Bool {
		TrollStoreHandoff.installedByTrollStore()
	}

	@ViewBuilder
	private func _preflightRow(_ report: InstallMethodReport) -> some View {
		let isSelected = (report.method == .server && _installationMethod == 0)
			|| (report.method == .idevice && _installationMethod == 1)
			|| (report.method == .liveContainer && _installationMethod == 2)

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

				// Status is always text as well as colour, never colour alone.
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
		case .ready:		return .green
		case .missing:		return .orange
		case .unavailable:	return .secondary
		case .unknown:		return .secondary
		}
	}
}
