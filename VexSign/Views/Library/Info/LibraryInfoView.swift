//
//  LibraryInfoView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 14.04.2025.
//

import SwiftUI
import NimbleViews
import Zsign
import UIKit
import NimbleExtensions

// MARK: - View
struct LibraryInfoView: View {
	var app: AppInfoPresentable
	@State private var _displayedDescription: String?
	@State private var _isClonePresenting = false
	@ObservedObject private var _appStoreTracker = AppStoreUpdateTracker.shared
	@ObservedObject private var _status = LibraryStatusStore.shared

	// MARK: Body
    var body: some View {
		NBNavigationView(app.name ?? "", displayMode: .inline) {
			List {
				Section {} header: {
					FRAppIconView(app: app)
						.frame(maxWidth: .infinity, alignment: .center)
				}

				_infoSection(for: app)
				_signatureSection(for: app)
				_certSection(for: app)
				_bundleSection(for: app)
				_executableSection(for: app)

				_resignSection()
				_cloneSection()
				_appStoreSection()

				Section {
					_linksSection(for: app)
					Button(.localized("Open in Files"), systemImage: "folder") {
						UIApplication.open(Storage.shared.getUuidDirectory(for: app)!.toSharedDocumentsURL()!)
					}
				}
			}
			.toolbar {
				NBToolbarButton(role: .close)
			}
		}
		.onAppear {
			_displayedDescription = app.appDescription
		}
		.sheet(isPresented: $_isClonePresenting) {
			AppCloneSheet(app: app)
		}
		.task {
			await LibraryStatusStore.shared.request(app, force: true)
		}
		.task {
			guard AppStoreUpdateTracker.isEnabled else { return }
			await _appStoreTracker.refresh(apps: [app])
		}
    }
}

// MARK: - Extension: View
extension LibraryInfoView {
	@ViewBuilder
	private func _resignSection() -> some View {
		if app.isSigned {
			NBSection(.localized("Re-sign")) {
				Button {
					_resignWithLastSettings()
				} label: {
					Label(
						.localized(SigningProfileStore.shared.profile(forBundleID: app.identifier) != nil
							? "Re-sign with last settings"
							: "Sign again"),
						systemImage: "signature"
					)
				}
			} footer: {
				Text(.localized("Signs this app again with the tweaks, entitlements and certificate it used before. Install it again afterwards, or export it."))
			}
		}
	}

	private func _resignWithLastSettings() {
		guard AutoSignManager.canSign else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Auto sign needs a certificate. Import one in Settings → Certificates.")
			)
			return
		}

		Task {
			switch await AutoSignManager.shared.sign(app) {
			case .success:
				Toast.success(.localized("Signed successfully"), systemImage: "checkmark.seal.fill")
			case .failure(let error):
				Toast.error(error.localizedDescription, duration: .sticky)
			}
		}
	}

	/// Duplicate this app under a new name and bundle ID.
	@ViewBuilder
	private func _cloneSection() -> some View {
		NBSection(.localized("Clone")) {
			Button {
				_isClonePresenting = true
			} label: {
				Label(.localized("Clone App"), systemImage: "doc.on.doc")
			}
		} footer: {
			Text(.localized("Creates a second copy with its own name and bundle identifier, so both can be installed side by side."))
		}
	}

	/// Newer public version on the App Store, when tracking is enabled and the
	/// bundle ID is listed there.
	@ViewBuilder
	private func _appStoreSection() -> some View {
		if let info = _appStoreTracker.info(for: app.identifier) {
			NBSection(.localized("App Store")) {
				LabeledContent(.localized("Latest Version"), value: info.version)

				if let date = info.releaseDate {
					LabeledContent(.localized("Released"), value: date.formatted(date: .abbreviated, time: .omitted))
				}

				if _appStoreTracker.hasNewerVersion(than: app) {
					Text(.localized("A newer version is available on the App Store."))
						.font(.footnote)
						.foregroundStyle(.orange)
				}

				if let storeURL = info.storeURL, let url = URL(string: storeURL) {
					Button {
						UIApplication.shared.open(url)
					} label: {
						Label(.localized("Open in App Store"), systemImage: "arrow.up.forward.app")
					}
				}
			}
		}
	}

	@ViewBuilder
	private func _infoSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Info")) {
			if let name = app.name {
				_infoCell(.localized("Name"), desc: name)
			}

			if let ver = app.version {
				_infoCell(.localized("Version"), desc: ver)
			}

			if let id = app.identifier {
				_infoCell(.localized("Identifier"), desc: id)
			}

			if let originalId = app.originalIdentifier, originalId != app.identifier {
				_infoCell(.localized("Original Identifier"), desc: originalId)
			}

			NavigationLink {
				SigningDescriptionView(
					title: .localized("Description"),
					initialValue: LinkTagParser.strip(from: _displayedDescription) ?? "",
					onSave: { newValue in
						var saved = newValue
						if let tags = LinkTagParser.rawTags(in: _displayedDescription) {
							saved = saved.map { $0 + tags } ?? tags
						}
						Storage.shared.updateDescription(for: app, description: saved)
						_displayedDescription = saved
					}
				)
			} label: {
				LabeledContent(.localized("Description")) {
					Text(verbatim: LinkTagParser.strip(from: _displayedDescription) ?? String.localized("None"))
						.lineLimit(1)
				}
			}
			.copyableText(LinkTagParser.strip(from: _displayedDescription) ?? "")

			if let date = app.date {
				_infoCell(.localized("Date Added"), desc: date.formatted())
			}
		}
	}
	
	/// What the device and the stored signature actually say.
	///
	/// This is the sheet where a user asks "why is this not updating?" — so it shows the
	/// certificate the bundle carries, its expiry, and whether it is the certificate the library
	/// entry points at.
	@ViewBuilder
	private func _signatureSection(for app: AppInfoPresentable) -> some View {
		let status = _status.status(for: app)
		let rows = status.signatureRows(certificateRow: _certificateMatchRow(for: app, status: status))

		if app.isSigned, !rows.isEmpty {
			NBSection(.localized("Signature")) {
				ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
					_infoCell(row.title, desc: row.value)
				}
			}
		}
	}

	/// Whether the certificate on the entry is the one the bundle carries, in one sentence.
	private func _certificateMatchRow(for app: AppInfoPresentable, status: LibraryAppStatus) -> String? {
		guard
			let certificate = Storage.shared.getCertificate(from: app),
			let signature = status.signature
		else {
			return nil
		}

		return CertificateIdentity.match(state: signature, certificate: certificate).summary
	}

	@ViewBuilder
	private func _certSection(for app: AppInfoPresentable) -> some View {
		if let cert = Storage.shared.getCertificate(from: app) {
			NBSection(.localized("Certificate")) {
				CertificatesCellView(
					cert: cert
				)
			}
		}
	}
	
	@ViewBuilder
	private func _bundleSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Bundle")) {
			NavigationLink(.localized("Browse Files")) {
				IPALibraryExplorerView(app: app, embedded: true)
			}
			NavigationLink(.localized("Alternative Icons")) {
				SigningAlternativeIconView(app: app, appIcon: .constant(nil), isModifing: false)
			}
			NavigationLink(.localized("Frameworks & PlugIns")) {
				SigningFrameworksView(app: app, options: .constant(nil))
			}
		}
	}
	
	@ViewBuilder
	private func _executableSection(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Executable")) {
			NavigationLink(.localized("Dylibs")) {
				SigningDylibView(app: app, options: .constant(nil))
			}
		}
	}
	
	@ViewBuilder
	private func _linksSection(for app: AppInfoPresentable) -> some View {
		ForEach(LinkTagParser.links(in: _displayedDescription)) { link in
			Button {
				link.tag.open(link.url)
			} label: {
				Label {
					Text(link.tag.title)
				} icon: {
					Image(systemName: link.tag.symbol)
				}
			}
		}
	}

	@ViewBuilder
	private func _infoCell(_ title: String, desc: String) -> some View {
		LabeledContent(title) {
			Text(desc)
		}
		.copyableText(desc)
	}
}
