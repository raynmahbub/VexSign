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

struct OnboardingView: View {
    @EnvironmentObject private var services: AppContainer
    @State private var importTask: Task<Void, Never>?
    @State private var importingPackage = false
    @State private var isVisible = false
	@Environment(\.dismiss) private var dismiss
	@AppStorage("VexSign.onboardingCompleted") private var _completed = false
	@AppStorage("VexSign.installationMethod") private var _installMethod = 0
	@State private var _page = 0
	@State private var _isAddingCert = false
	@State private var _isChoosingSigningMethod = false
	@State private var _isAddingSource = false
	@State private var _isImportingIPA = false
	@State private var _importedAppName: String?

	@WorkspaceQuery(\.certificates, order: .stored) private var _certificates: [CertificateRecord]

	@WorkspaceQuery(\.repositories, order: .stored) private var _sources: [RepositoryRecord]

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
					.font(Theme.Typography.rowTitle)
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
			.sheet(isPresented: $_isChoosingSigningMethod) {
                NBNavigationView(.localized("Signing Methods")) {
                    SigningMethodsView()
                }
            }
			.sheet(isPresented: $_isAddingSource) {
				SourcesAddView()
			}
			.fileImporter(isPresented: $_isImportingIPA, allowedContentTypes: UTType.packageArchives, allowsMultipleSelection: false) { result in
				if case .success(let urls) = result, let url = urls.first {
					_importFirstApp(from: url)
				}
			}
		}
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; importTask?.cancel() }
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
			Text(.localized("Certificate-based signing runs on this device. Apple Account setup contacts Apple and your configured Anisette provider; optional remote services have separate trust boundaries."))
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			BootstrapFact()
			Spacer()
		}
		.padding(28)
	}

	private var _pageCertificate: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(.localized("Set up signing"))
				.font(.title2.weight(.semibold))
			Text(.localized("Choose Paid Certificate to import your .p12, its password and a compatible .mobileprovision profile. Choose Free Apple ID to review account provisioning and its current limits. Account setup and installation are separate steps; neither bypasses device or profile requirements."))
				.foregroundStyle(.secondary)
			Button {
                _isChoosingSigningMethod = true
            } label: {
                Label(.localized("Choose Signing Method"), systemImage: "signature")
            }
            .buttonStyle(.borderedProminent)
			Button {
				_isAddingCert = true
			} label: {
				Label(.localized("Import Certificate"), systemImage: "plus")
			}
			.buttonStyle(.borderedProminent)

			if !_certificates.isEmpty {
				Label(
					String.localized("%lld certificate(s) imported — preflight still required", arguments: _certificates.count),
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
        guard !importingPackage else { return }
        importingPackage = true
        importTask = Task { @MainActor in
            defer { importingPackage = false; importTask = nil }
            do {
                let app = try await services.library.importPackage(url)
                guard !Task.isCancelled, isVisible else { return }
                _importedAppName = app.name ?? url.lastPathComponent
            } catch is CancellationError {
                // The import owner waits for cleanup; a committed artifact is retained.
            } catch {
                if isVisible { Toast.error(error.localizedDescription, systemImage: "exclamationmark.triangle") }
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
            .disabled(importingPackage)

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
            NavigationLink(destination: DiagnosticsCenterView()) {
                Label(.localized("Diagnostics Center"), systemImage: "stethoscope")
            }
            Text(.localized("If a step fails, open Diagnostics Center and export a diagnostic bundle. Review it before sharing. A submitted install is not confirmation that iOS installed the app."))
                .font(.footnote)
                .foregroundStyle(.secondary)
			Spacer()
		}
		.padding(28)
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

/// The one thing a new user has to understand before anything else works: VexSign cannot perform
/// its own *first* install.
///
/// The app is already installed by the time this screen appears, which makes the question "how
/// did it get here, and how do I get the next copy" easy to skip — and then a failed install or a
/// missing store route reads as a bug. The bootstrap routes are covered by
/// `README.md`; this card is the sentence that matters
/// at first launch. Updates are the exception and are named as one: a signed copy in Library can be
/// installed in place from the update sheet, which needs no installer at all.
private struct BootstrapFact: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Label(.localized("VexSign cannot perform its first install by itself"), systemImage: "exclamationmark.shield")
				.font(.subheadline.weight(.semibold))
			Text(.localized("This copy is already installed. Getting VexSign onto a device in the first place needs one of: an existing installer such as SideStore or AltStore, a signed IPA installed through Xcode, or an OTA/enterprise route you already trust. Updates do not: sign the release in Library with the certificate this build was signed with, and the update sheet installs it in place. Nothing is ever sent to an updater."))
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			if EmbeddedContainerRuntime.isAvailable {
				Text(.localized("This combined build can also host LiveContainer guests."))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
		.accessibilityElement(children: .combine)
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
