//
//  OnboardingView.swift
//  VexSign
//
//  First-run setup wizard: what VexSign is, import a certificate, add a
//  repository, import the first IPA and pick the install method. Every step
//  is optional — each page states what it does and where to find it later.
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import UniformTypeIdentifiers
import CoreData

struct OnboardingView: View {
	@Environment(\.dismiss) private var dismiss
	@AppStorage("VexSign.onboardingCompleted") private var _completed = false
	@AppStorage("VexSign.installationMethod") private var _installMethod = 0
	@State private var _page = 0
	@State private var _isAddingCert = false
	@State private var _isAddingSource = false
	@State private var _isImportingIPA = false
	@State private var _importedAppName: String?

	@FetchRequest(entity: CertificatePair.entity(), sortDescriptors: [])
	private var _certificates: FetchedResults<CertificatePair>

	@FetchRequest(entity: AltSource.entity(), sortDescriptors: [])
	private var _sources: FetchedResults<AltSource>

	private let _pageCount = 5

	var body: some View {
		NBNavigationView(.localized("Welcome")) {
			TabView(selection: $_page) {
				_pageWelcome.tag(0)
				_pageCertificate.tag(1)
				_pageSource.tag(2)
				_pageFirstApp.tag(3)
				_pageInstall.tag(4)
			}
			.tabViewStyle(.page(indexDisplayMode: .always))
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(_page == _pageCount - 1 ? .localized("Done") : .localized("Next")) {
						if _page < _pageCount - 1 {
							_page += 1
						} else {
							_completed = true
							dismiss()
						}
					}
					.font(.body.weight(.semibold))
				}
				if _page > 0 {
					ToolbarItem(placement: .topBarLeading) {
						Button(.localized("Back")) { _page -= 1 }
					}
				}
			}
			.sheet(isPresented: $_isAddingCert) {
				CertificatesAddView()
					.presentationDetents([.medium])
			}
			.sheet(isPresented: $_isAddingSource) {
				SourcesAddView()
			}
			.fileImporter(isPresented: $_isImportingIPA, allowedContentTypes: [.ipa, .tipa, .item], allowsMultipleSelection: false) { result in
				if case .success(let urls) = result, let url = urls.first {
					_importFirstApp(from: url)
				}
			}
		}
		.interactiveDismissDisabled(!_completed && _page < _pageCount - 1)
	}

	// MARK: - Pages

	private var _pageWelcome: some View {
		VStack(spacing: 16) {
			Image(systemName: "signature")
				.font(.system(size: 48))
				.foregroundStyle(Color.accentColor)
			Text(.localized("Sign and install apps on this device."))
				.font(.title2.weight(.semibold))
				.multilineTextAlignment(.center)
			Text(.localized("VexSign uses your certificate to sign IPAs, then installs them over the local server or a pairing file. Nothing is uploaded."))
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			Spacer()
		}
		.padding(28)
	}

	private var _pageCertificate: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(.localized("Set up signing"))
				.font(.title2.weight(.semibold))
			Text(.localized("Import a .p12 and .mobileprovision pair to sign apps directly on this device. You can skip this now and configure Paid Certificate, Free Apple ID, SideStore/LiveContainer, or TrollStore later in Settings → Signing Methods."))
				.foregroundStyle(.secondary)
			Button {
				_isAddingCert = true
			} label: {
				Label(.localized("Import Certificate"), systemImage: "plus")
			}
			.buttonStyle(.borderedProminent)

			if !_certificates.isEmpty {
				Label(
					String.localized("%lld certificate(s) ready", arguments: _certificates.count),
					systemImage: "checkmark.circle.fill"
				)
				.font(.footnote)
				.foregroundStyle(.green)
			}
			Spacer()
		}
		.padding(28)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var _pageSource: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(.localized("Add a repository"))
				.font(.title2.weight(.semibold))
			Text(.localized("Repositories (sources) are app catalogs. Add one to browse and download IPAs directly in the App Store tab — you can add more any time."))
				.foregroundStyle(.secondary)
			Button {
				_isAddingSource = true
			} label: {
				Label(.localized("Add Source"), systemImage: "plus")
			}
			.buttonStyle(.borderedProminent)

			if !_sources.isEmpty {
				Label(
					String.localized("%lld source(s) added", arguments: _sources.count),
					systemImage: "checkmark.circle.fill"
				)
				.font(.footnote)
				.foregroundStyle(.green)
			}
			Spacer()
		}
		.padding(28)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	/// Imports the file the wizard's picker returned, using the same path the
	/// Files tab uses, and remembers the name for the confirmation row.
	private func _importFirstApp(from url: URL) {
		let scoped = url.startAccessingSecurityScopedResource()
		defer {
			if scoped {
				url.stopAccessingSecurityScopedResource()
			}
		}

		PackageImportService.importPackage(url) { result in
			switch result {
			case .success(let app):
				_importedAppName = app.name ?? url.lastPathComponent
			case .failure(let error):
				Toast.error(error.localizedDescription, systemImage: "exclamationmark.triangle")
			}
		}
	}

	private var _pageFirstApp: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(.localized("Import your first app"))
				.font(.title2.weight(.semibold))
			Text(.localized("Already have an IPA or TIPA file? Import it now — it lands in your Library, ready to sign. You can also download apps from your repositories, or drop a file onto Home."))
				.foregroundStyle(.secondary)
			Button {
				_isImportingIPA = true
			} label: {
				Label(_importedAppName == nil ? .localized("Choose File") : .localized("Choose Another"), systemImage: "square.and.arrow.down")
			}
			.buttonStyle(.bordered)

			if let name = _importedAppName {
				Label(String.localized("Imported %@", arguments: name), systemImage: "checkmark.circle.fill")
					.font(.footnote)
					.foregroundStyle(.green)
			}
			Spacer()
		}
		.padding(28)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var _pageInstall: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(.localized("How should apps install?"))
				.font(.title2.weight(.semibold))
			PicketInstall(method: $_installMethod, hasEmbeddedRuntime: EmbeddedContainerRuntime.isAvailable)
			Text(.localized("Local Server requires installing and trusting VexSign's local Root CA in iOS Settings → Certificate Trust Settings. Pairing (idevice) needs a pairing file and a loopback VPN. Review readiness any time in Settings → Setup Health."))
				.font(.footnote)
				.foregroundStyle(.secondary)
			Spacer()
		}
		.padding(28)
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

private struct PicketInstall: View {
	@Binding var method: Int
	var hasEmbeddedRuntime: Bool

	var body: some View {
		VStack(spacing: 10) {
			_row(0, title: .localized("Local Server"), detail: .localized("itms-services over HTTPS after trusting the local Root CA."))
			_row(1, title: .localized("Pairing / idevice"), detail: .localized("Needs a pairing file and loopback VPN. Fast once set up."))
			if hasEmbeddedRuntime {
				_row(2, title: .localized("Embedded LiveContainer"), detail: .localized("Imports the app as a container guest inside this host."))
			}
		}
	}

	private func _row(_ value: Int, title: String, detail: String) -> some View {
		Button {
			method = value
		} label: {
			HStack {
				VStack(alignment: .leading, spacing: 2) {
					Text(title).font(.body.weight(.medium))
					Text(detail).font(.caption).foregroundStyle(.secondary)
				}
				Spacer()
				if method == value {
					Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
				}
			}
			.padding()
			.background(Color(.quaternarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		}
		.buttonStyle(.plain)
	}
}
