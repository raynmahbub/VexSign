//
//  ServerView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 6.05.2025.
//

import SwiftUI
import NimbleJSON
import NimbleViews
import NimbleExtensions

// MARK: - Extension: Model
extension ServerView {
	struct ServerPackModel: Decodable {
		var cert: String
		var ca: String
		var key: String
		var info: ServerPackInfo
		
		private enum CodingKeys: String, CodingKey {
			case cert, ca, key1, key2, info
		}
		
		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			cert = try container.decode(String.self, forKey: .cert)
			ca = try container.decode(String.self, forKey: .ca)
			let key1 = try container.decode(String.self, forKey: .key1)
			let key2 = try container.decode(String.self, forKey: .key2)
			key = key1 + key2
			info = try container.decode(ServerPackInfo.self, forKey: .info)
		}
		
		struct ServerPackInfo: Decodable {
			var issuer: Domains
			var domains: Domains
		}
		
		struct Domains: Decodable {
			var commonName: String
			
			private enum CodingKeys: String, CodingKey {
				case commonName = "commonName"
			}
		}
	}
}

// MARK: - View
struct ServerView: View {
	@AppStorage("VexSign.ipFix") private var _ipFix: Bool = false
	@AppStorage("VexSign.serverMethod") private var _serverMethod: Int = 0
	private let _serverMethods: [String] = [.localized("Fully Local"), .localized("Semi Local")]

	private let _dataService = NBFetchService()
	private let _serverPackUrl = "https://vexsign-install.vexsign.workers.dev/pack.json"

	/// What the local server would serve HTTPS with right now. Shown, not hidden:
	/// which identity is in use is exactly the thing a failed install needs to know.
	@State private var _identity: LocalTLSIdentity.Summary?
	@State private var _isUpdating = false

	// MARK: Body
	var body: some View {
		Group {
			Section {
				Picker(.localized("Server Type"), systemImage: "server.rack", selection: $_serverMethod) {
					ForEach(_serverMethods.indices, id: \.description) { index in
						Text(_serverMethods[index]).tag(index)
					}
				}
				Toggle(.localized("Only use localhost address"), systemImage: "lifepreserver", isOn: $_ipFix)
					.disabled(_serverMethod != 1)
			} footer: {
				Text(.localized("Fully Local serves the manifest and IPA from this device over HTTPS. It requires valid SSL certificates and a hostname that resolves to this device. Semi Local uses an online manifest service, while the IPA stays on your device. If the LAN address fails, enable Only use localhost address."))
			}

			Section {
				Button(.localized("Update SSL Certificates"), systemImage: "arrow.down.doc") {
					_confirmUpdate()
				}
				.disabled(_isUpdating)

				if _identity?.source == .installed {
					Button(.localized("Use the Identity From This Build"), systemImage: "arrow.uturn.backward") {
						_restoreBundled()
					}
				}

				Button(.localized("Export Root CA Profile (.mobileconfig)"), systemImage: "lock.shield") {
					_exportRootCA()
				}
			} footer: {
				_identityFooter
			}
		}
		.onAppear {
			_identity = LocalTLSIdentity.current()
		}
	}

	/// The identity line plus the one thing that actually breaks installs.
	@ViewBuilder
	private var _identityFooter: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(.localized("Export and install the Root CA profile in Settings to trust the local HTTPS server for offline installations. After installing the profile, enable Full Trust under Settings → General → About → Certificate Trust Settings."))

			if let identity = _identity {
				Text(identity.detail)
					.font(.footnote)

				if identity.mode == .development {
					Text(.localized("This build ships a self-signed development identity. Install and trust its Root CA profile, or HTTPS installs will fail."))
						.font(.footnote)
						.foregroundStyle(.orange)
				}
			} else {
				Text(.localized("No certificate found. HTTPS installs will fail until an identity is installed."))
					.font(.footnote)
					.foregroundStyle(.orange)
			}
		}
	}
}

// MARK: - Extension: Actions
extension ServerView {
	/// Replaces the identity the local server presents, so the user needs to know exactly what
	/// that means before it happens — this is a network fetch of a certificate and its private key.
	private func _confirmUpdate() {
		var message: String = .localized(
			"This downloads the certificate the project publishes for the local install server and replaces the one on this device. The download is checked before anything is replaced. If the root certificate changes, you will have to export and trust the new Root CA profile."
		)

		if let identity = _identity {
			message += "\n\n" + identity.detail
		}

		UIAlertController.showAlertWithOptions(
			title: .localized("Update SSL Certificates?"),
			message: message,
			actions: [
				(.localized("Download"), .default, {
					_update()
				}),
				(.localized("Cancel"), .cancel, nil)
			]
		)
	}

	private func _update() {
		_isUpdating = true

		FR.downloadSSLCertificates(from: _serverPackUrl) { result in
			DispatchQueue.main.async {
				_isUpdating = false
				_identity = LocalTLSIdentity.current()

				switch result {
				case .success(let summary):
					UIAlertController.showAlertWithOk(
						title: .localized("SSL Certificates"),
						message: summary.map {
							.localized(
								"Identity installed: %@, %@. Export the Root CA profile and enable full trust if installs fail.",
								arguments: $0.commonName,
								$0.expiryDescription
							)
						} ?? .localized("Identity installed.")
					)
				case .failure(let error):
					UIAlertController.showAlertWithOk(
						title: .localized("SSL Certificates"),
						message: error.localizedDescription
					)
				}
			}
		}
	}

	/// Drops the downloaded identity so the one built into the app is used again.
	private func _restoreBundled() {
		let documents = URL.documentsDirectory
		for name in ["server.pem", "server.crt", "commonName.txt"] {
			try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))
		}

		_identity = LocalTLSIdentity.current()

		UIAlertController.showAlertWithOk(
			title: .localized("SSL Certificates"),
			message: .localized("The identity bundled with this build is in use again. Trust its Root CA profile if installs fail.")
		)
	}

	private func _exportRootCA() {
		guard let profileURL = LocalCAProfile.exportProfile() else {
			UIAlertController.showAlertWithOk(
				title: .localized("Export Failed"),
				message: .localized("No server certificate found. Please download or update SSL certificates first.")
			)
			return
		}
		
		UIActivityViewController.show(activityItems: [profileURL])
	}
}
