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
	@AppStorage("VexSign.installationMethod") private var _installationMethod: Int = 0
	@State private var _showMethodChangedAlert = false
	@State private var _preflight = InstallPreflightInputs()

	private let _installationMethods: [String] = [
		.localized("Server"),
		.localized("idevice")
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
				Text(.localized("Server (Recommended):\nUses a locally hosted server and itms-services:// to install applications.\n\nIDevice (advanced):\nUses a VPN and a pairing file. Writes to AFC and manually calls installd, while monitoring install progress by using a callback\nAdvantage: It is very reliable, does not need SSL certificates or a externally hosted server. Rather, works similarly to a computer."))
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
				Text(.localized("These are the same routes the Install button chooses between. A route marked Ready is not a promise that the device will accept the app — it means the thing it needs from VexSign is there."))
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
			}
		}
		.onChange(of: _installationMethod) { newValue in
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
				"This installation method is intended for advanced users only!\n\nIt requires a VPN and a pairing file from a PC.\n\nIts recommended you go back to the server installation method."
			))
		}
		.onAppear(perform: _refreshPreflight)
		.onChange(of: _installationMethod) { _ in _refreshPreflight() }
		.animation(.default, value: _installationMethod)
    }

	// MARK: Preflight

	private func _refreshPreflight() {
		_preflight = InstallPreflightInputs(
			hasServerCertificate: LocalTLSIdentity.current() != nil,
			hasPairingFile: FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()),
			trollStoreDetected: _trollStoreDetected()
		)
	}

	/// TrollStore answers one of two URL schemes. iOS only reports a scheme that is declared in
	/// `LSApplicationQueriesSchemes`; both are, so a false here means "not installed", not "not allowed".
	private func _trollStoreDetected() -> Bool {
		["apple-magnifier://", "trollstore://"].contains { string in
			guard let url = URL(string: string) else { return false }
			return UIApplication.shared.canOpenURL(url)
		}
	}

	@ViewBuilder
	private func _preflightRow(_ report: InstallMethodReport) -> some View {
		let isSelected = (report.method == .server && _installationMethod == 0)
			|| (report.method == .idevice && _installationMethod == 1)

		VStack(alignment: .leading, spacing: 3) {
			HStack(spacing: 6) {
				Text(report.method.title)
					.font(.subheadline.weight(.semibold))
					.lineLimit(1)

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
