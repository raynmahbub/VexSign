//
//  WebManagerView.swift
//  VexSign
//
//  Controls the Web Manager server: HTTP upload page + WebDAV mount.
//

import SwiftUI
import Security
import NimbleViews
import NimbleExtensions
import CoreImage.CIFilterBuiltins

// MARK: - View
struct WebManagerView: View {
	@ObservedObject private var manager = WebManager.shared

	@State private var showNetworkExposureConfirmation = false
	@State private var showRemovePasswordConfirmation = false

	// MARK: Body
	var body: some View {
		NBList(.localized("Web Manager")) {
			_serverSection
			if manager.isRunning {
				_connectSection
			}
			_accessSection
			_serverSettingsSection
			_recentSection
		}
		.dismissableKeyboard()
		.animation(.smooth, value: manager.isRunning)
		.animation(.smooth, value: manager.recentUploads)
		.animation(.smooth, value: manager.authActive)
		.animation(.smooth, value: manager.effectiveBindMode)
	}
}

// MARK: - Sections
extension WebManagerView {
	@ViewBuilder
	private var _serverSection: some View {
		NBSection(.localized("Server")) {
			Toggle(isOn: Binding(
				get: { manager.isRunning },
				set: { _ in manager.toggle() }
			)) {
				Label(.localized("Enable Server"), systemImage: "externaldrive.badge.wifi")
			}

			if let error = manager.lastError {
				Label(error, systemImage: "exclamationmark.triangle")
					.foregroundStyle(.red)
					.font(.footnote)
			}

			// A running server always states its exposure.
			if manager.isRunning {
				Label(manager.exposureSummary, systemImage: manager.authActive ? "lock.fill" : "lock.open")
					.font(.footnote)
					.foregroundStyle(manager.authActive ? Color.secondary : Color.orange)
			}

			if manager.isBindDowngraded {
				Label(
					.localized("Network access is off because no password is set. Set a password, or allow it explicitly below."),
					systemImage: "wifi.slash"
				)
				.foregroundStyle(.orange)
				.font(.footnote)
			}
		} footer: {
			Text(.localized("Upload files and manage your apps, certificates and tweaks from a browser or a mounted drive. Requires a username and password unless you choose to run it on this device only."))
		}
		// One-time explanation for installs that used to run the server open.
		.alert(
			.localized("Password protection is on"),
			isPresented: Binding(
				get: { manager.needsAuthExplanation },
				set: { manager.needsAuthExplanation = $0 }
			)
		) {
			Button(.localized("OK"), role: .cancel) { manager.needsAuthExplanation = false }
		} message: {
			Text(.localized("The Web Manager used to start without a password. It now requires one, because an open server on a local network can hand out your signing certificates and delete your apps. Set a username and password in Access — or turn Require Password off to keep the server on this device only."))
		}
	}

	@ViewBuilder
	private var _connectSection: some View {
		NBSection(.localized("Connect")) {
			_urlRow(.localized("Browser"), value: manager.httpURL, systemImage: "safari")
			_urlRow(.localized("WebDAV (Finder)"), value: manager.webdavURL, systemImage: "externaldrive.connected.to.line.below")

			HStack {
				Spacer()
				if let qr = QRCode.generate(from: manager.httpURL) {
					Image(uiImage: qr)
						.interpolation(.none)
						.resizable()
						.frame(width: 160, height: 160)
						.padding(8)
						.background(Color.white)
						.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
				}
				Spacer()
			}
			.listRowBackground(EmptyView())
		} footer: {
			if manager.effectiveBindMode == .thisDevice {
				Text(.localized("Only this device can connect while the server listens on 127.0.0.1. Turn on “Allow this network” to reach it from a computer, the Files app on another device, or the Apple TV app."))
			} else {
				Text(.localized("Scan the code to open the Web Manager, or mount the WebDAV address in Finder (Go → Connect to Server) or the Files app. Traffic is unencrypted on the local network."))
			}
		}
	}

	@ViewBuilder
	private func _urlRow(_ title: String, value: String, systemImage: String) -> some View {
		Button {
			UIPasteboard.general.string = value
			Toast.info(.localized("Copied"), systemImage: "doc.on.doc.fill")
		} label: {
			HStack {
				Label(title, systemImage: systemImage)
				Spacer()
				Text(value)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
				Image(systemName: "doc.on.doc")
					.font(.footnote)
					.foregroundStyle(.tint)
			}
		}
	}

	@ViewBuilder
	private var _accessSection: some View {
		NBSection(.localized("Access")) {
			Toggle(isOn: Binding(
				get: { manager.effectiveBindMode == .localNetwork },
				set: { wantsNetwork in
					if wantsNetwork {
						if manager.authActive {
							manager.bindMode = .localNetwork
							manager.restartIfRunning()
						} else {
							// Requires an explicit confirmation: no password + network.
							showNetworkExposureConfirmation = true
						}
					} else {
						manager.bindMode = .thisDevice
						manager.allowUnauthenticatedLAN = false
						manager.restartIfRunning()
					}
				}
			)) {
				Label(.localized("Allow This Network"), systemImage: "wifi.router")
			}

			Toggle(isOn: Binding(
				get: { manager.requireAuth },
				set: { enabled in
					if enabled {
						manager.requireAuth = true
						manager.restartIfRunning()
					} else {
						showRemovePasswordConfirmation = true
					}
				}
			)) {
				Label(.localized("Require Password"), systemImage: "lock")
			}

			if manager.requireAuth {
				HStack {
					Label(.localized("Username"), systemImage: "person")
					Spacer()
					TextField(.localized("Username"), text: Binding(
						get: { manager.username },
						set: { manager.username = $0 }
					))
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.multilineTextAlignment(.trailing)
					.onSubmit { manager.restartIfRunning() }
				}
				HStack {
					Label(.localized("Password"), systemImage: "key")
					Spacer()
					SecureField(.localized("Password"), text: Binding(
						get: { manager.password },
						set: { manager.password = $0 }
					))
					.multilineTextAlignment(.trailing)
					.onSubmit { manager.restartIfRunning() }
				}

				if manager.password.isEmpty {
					Label(.localized("Set a password — until you do, the server will not start."), systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange)
						.font(.footnote)
				}
			}

			Toggle(isOn: Binding(
				get: { manager.allowCertificateExport },
				set: { manager.allowCertificateExport = $0; manager.restartIfRunning() }
			)) {
				Label(.localized("Allow Certificate Download"), systemImage: "arrow.down.doc")
			}

			HStack {
				Label(.localized("API Token"), systemImage: "key.horizontal")
				Spacer()
				SecureField(.localized("Optional"), text: Binding(
					get: { manager.apiToken },
					set: { manager.apiToken = $0 }
				))
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.multilineTextAlignment(.trailing)
				.onSubmit { manager.restartIfRunning() }
			}

			Button {
				manager.apiToken = Self._randomToken()
				manager.restartIfRunning()
			} label: {
				Label(.localized("Generate Token"), systemImage: "dice")
			}

			if manager.tokenActive {
				Button(role: .destructive) {
					manager.apiToken = ""
					manager.restartIfRunning()
				} label: {
					Label(.localized("Remove Token"), systemImage: "trash")
				}
			}
		} footer: {
			Text(.localized("A token is a full credential: on every endpoint it stands in for the username and password, so the Apple TV app and scripts can hold their own secret instead of your password. Certificate download and every delete action are always locked — they need the password, and when a token is set they need that token too, which also locks the browser's certificate list. Changing any of these restarts the server."))
		}
		// No password + "reachable from the network" is an explicit decision, never a side effect.
		.alert(
			.localized("Expose this server without a password?"),
			isPresented: $showNetworkExposureConfirmation
		) {
			Button(.localized("Allow This Network"), role: .destructive) {
				manager.allowUnauthenticatedLAN = true
				manager.bindMode = .localNetwork
				manager.restartIfRunning()
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			Text(.localized("Anyone on this network could browse, upload and delete files, and reach the API. Certificate and signing endpoints stay locked until a password or API token is set. Use this only on a network you control."))
		}
		.alert(
			.localized("Turn off the password?"),
			isPresented: $showRemovePasswordConfirmation
		) {
			Button(.localized("Turn Off"), role: .destructive) {
				manager.requireAuth = false
				manager.restartIfRunning()
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			Text(.localized("Without a password the server only accepts connections from this device, and the certificate and signing endpoints stay locked until you set a password or an API token."))
		}
	}

	@ViewBuilder
	private var _serverSettingsSection: some View {
		NBSection(.localized("Settings")) {
			HStack {
				Label(.localized("Port"), systemImage: "number")
				Spacer()
				TextField("8080", text: Binding(
					get: { String(manager.port) },
					set: { manager.port = Int($0.filter(\.isNumber)) ?? manager.port }
				))
				.keyboardType(.numberPad)
				.multilineTextAlignment(.trailing)
				.frame(width: 80)
				.onSubmit { manager.restartIfRunning() }
			}
		} footer: {
			Text(.localized("Changing the port restarts the server. Traffic is sent over your local network unencrypted, so only run this on a network you trust."))
		}

		NBSection(.localized("Background")) {
			Toggle(isOn: Binding(
				get: { manager.keepAlive },
				set: { manager.keepAlive = $0 }
			)) {
				Label(.localized("Keep Alive"), systemImage: "bolt.badge.clock")
			}
		} footer: {
			Text(.localized("Keeps the server reachable while VexSign is in the background by playing silent audio. This noticeably increases battery drain — turn it off when you're done transferring."))
		}
	}

	@ViewBuilder
	private var _recentSection: some View {
		if !manager.recentUploads.isEmpty {
			NBSection(.localized("Recent Uploads"), secondary: "\(manager.recentUploads.count)") {
				ForEach(manager.recentUploads, id: \.self) { name in
					Label(name, systemImage: _icon(for: name))
						.lineLimit(1)
				}

				Button(role: .destructive) {
					manager.clearRecent()
				} label: {
					Label(.localized("Clear"), systemImage: "trash")
				}
			}
		}
	}

	private func _icon(for name: String) -> String {
		let n = name.lowercased()
		if n.hasSuffix(".ipa") || n.hasSuffix(".tipa") { return "app.badge" }
		if n.hasSuffix(".dylib") { return "doc.badge.gearshape" }
		if n.hasSuffix(".deb") { return "shippingbox" }
		return "doc"
	}

	/// 24 random bytes, URL-safe. Long enough that guessing is not a thing.
	private static func _randomToken() -> String {
		var bytes = [UInt8](repeating: 0, count: 24)
		guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
			return UUID().uuidString.replacingOccurrences(of: "-", with: "")
		}
		return Data(bytes)
			.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}
}

// MARK: - QR
enum QRCode {
	static func generate(from string: String) -> UIImage? {
		let context = CIContext()
		let filter = CIFilter.qrCodeGenerator()
		filter.message = Data(string.utf8)
		filter.correctionLevel = "M"

		guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
			return nil
		}
		guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
		return UIImage(cgImage: cg)
	}
}
