//
//  WebToolsView.swift
//  VexSign
//
//  Ecosystem → Web Tools. The six browser tools the backend serves: a signing
//  console, a repository creator, a repository decoder, an app installer, a
//  certificate status checker and a UDID grabber. They are the same code whether
//  you run the server yourself or use a hosted deployment — this screen is only a
//  launcher plus the address, so nothing about them is duplicated inside the app.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct WebToolsView: View {
	static let baseURLKey = "VexSign.webTools.baseURL"

	@AppStorage(WebToolsView.baseURLKey) private var _baseURL: String = ""

	private struct Tool: Identifiable {
		let id: String
		let path: String
		let title: String
		let detail: String
		let systemImage: String
	}

	private let _tools: [Tool] = [
		Tool(
			id: "signer",
			path: "/Tools/signer",
			title: .localized("Signer Console"),
			detail: .localized("Queue IPAs in a browser and get signed ones back. Signing still happens here on the device — the page relays to your Web Manager, so the server has to be able to reach it."),
			systemImage: "hammer"
		),
		Tool(
			id: "repo",
			path: "/Tools/repo-creator",
			title: .localized("Repository Creator"),
			detail: .localized("Build, validate and export a source feed, plus OTA manifests. Exports to your device — nothing is uploaded."),
			systemImage: "shippingbox"
		),
		Tool(
			id: "decoder",
			path: "/Tools/repo-decoder",
			title: .localized("Repository Decoder"),
			detail: .localized("Read any source feed — AltStore, SideStore, flat schema, apps.json or legacy XML — see what it contains and export it in another dialect."),
			systemImage: "doc.text.viewfinder"
		),
		Tool(
			id: "installer",
			path: "/Tools/app-installer",
			title: .localized("App Installer"),
			detail: .localized("Turn a hosted IPA into an install link, and probe the URL first so a download that never starts is caught here."),
			systemImage: "square.and.arrow.down.on.square"
		),
		Tool(
			id: "cert",
			path: "/Tools/cert-check",
			title: .localized("Certificate Status Checker"),
			detail: .localized("Read expiry, team, entitlements and device scope from a provisioning profile. It never accepts a .p12 or a password."),
			systemImage: "checkmark.shield"
		),
		Tool(
			id: "udid",
			path: "/Tools/udid",
			title: .localized("UDID Grabber"),
			detail: .localized("Install a one-time enrolment profile and read the UDID. Sessions expire after 15 minutes and are never stored."),
			systemImage: "iphone"
		)
	]

	var body: some View {
		NBList(.localized("Web Tools")) {
			_addressSection
			_toolsSection
			_honestySection
		}
	}

	// MARK: Address

	@ViewBuilder
	private var _addressSection: some View {
		Section {
			TextField(.localized("https://your-vexsign-server.example"), text: $_baseURL)
				.keyboardType(.URL)
				.autocorrectionDisabled()
				.textInputAutocapitalization(.never)
		} header: {
			Text(.localized("Server"))
		} footer: {
			Text(.localized("The address of a VexSign backend (the one in `Services/API/server/`). Every deployment serves these tools under /tools."))
		}
	}

	// MARK: Tools

	@ViewBuilder
	private var _toolsSection: some View {
		NBSection(.localized("Tools")) {
			ForEach(_tools) { tool in
				_row(tool)
			}
		}
	}

	@ViewBuilder
	private func _row(_ tool: Tool) -> some View {
		let url = _url(for: tool)

		Button {
			if let url {
				UIApplication.open(url)
			} else {
				// No server configured: hand over the path so the user can paste it
				// onto whatever host they run.
				UIPasteboard.general.string = tool.path
				Toast.info(.localized("Server address not set — copied the path instead"), systemImage: "doc.on.doc")
			}
		} label: {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text(tool.title)
					Text(tool.detail)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} icon: {
				Image(systemName: tool.systemImage)
					.foregroundStyle(url == nil ? Color.secondary : Color.accentColor)
			}
		}
		.disabled(false)
	}

	// MARK: Honesty

	@ViewBuilder
	private var _honestySection: some View {
		Section {
			Label {
				Text(.localized("These tools run on the server, not on your device. None of them hold a private key: signing always happens on the phone, and the Signer Console only relays to it. The repository creator and app installer host nothing — they hand you files to upload yourself."))
					.font(.caption)
					.foregroundStyle(.secondary)
			} icon: {
				Image(systemName: "info.circle")
					.foregroundStyle(.secondary)
			}
		}
	}

	// MARK: Helpers

	private func _url(for tool: Tool) -> URL? {
		let base = _baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !base.isEmpty else { return nil }
		let normalized = base.hasSuffix("/") ? String(base.dropLast()) : base
		return URL(string: normalized + tool.path)
	}
}
