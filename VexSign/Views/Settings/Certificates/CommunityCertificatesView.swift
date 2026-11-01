//
//  CommunityCertificatesView.swift
//  VexSign
//
//  Community certificate catalogue (NexCerts, hosted by sideloading.net).
//  Imported from NexStore; contained in so that the source, the shared
//  identity and its consequences are disclosed before anything is downloaded.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct CommunityCertificatesView: View {
	@Environment(\.dismiss) private var dismiss

	@State private var _catalogSections: [NexCerts.CatalogSection] = []
	@State private var _expandedGroups: Set<String> = []
	@State private var _errorMessage: String?
	@State private var _hasLoaded = false
	@State private var _isImporting = false
	@State private var _isLoading = false
	@State private var _importingCertificateID: String?
	@State private var _hasAcknowledged = NexCertsAccess.hasAcknowledged()
	@State private var _isReviewingSource = false
	@State private var _pendingImport: NexCerts.CatalogItem?

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Community Certificates"), displayMode: .inline) {
			Group {
				if !_hasAcknowledged || _isReviewingSource {
					_sourceDisclosure
				} else if _isLoading || !_hasLoaded {
					_loadingView
				} else if let errorMessage = _errorMessage {
					_errorView(message: errorMessage)
				} else {
					_catalogList
				}
			}
			.animation(.default, value: _catalogSections.map(\.id))
			.animation(.default, value: _isLoading)
			.animation(.default, value: _hasAcknowledged)
			.toolbar {
				NBToolbarButton(role: .cancel)

				if _isImporting {
					ToolbarItem(placement: .confirmationAction) {
						ProgressView()
					}
				}
			}
			.task(id: _hasAcknowledged) {
				guard _hasAcknowledged, !_hasLoaded else { return }
				await _loadCatalog()
			}
			.alert(
				.localized("Import Shared Certificate?"),
				isPresented: Binding(
					get: { _pendingImport != nil },
					set: { if !$0 { _pendingImport = nil } }
				),
				presenting: _pendingImport
			) { certificate in
				Button(.localized("Import")) {
					Task {
						await _import(certificate)
					}
				}
				Button(.localized("Cancel"), role: .cancel) { }
			} message: { certificate in
				Text(
					verbatim: String.localized(
						"%@ downloads this certificate, its profile and its password from %@. Everyone using this catalogue signs with the same identity.",
						arguments: certificate.name, NexCerts.sourceHost
					)
				)
			}
		}
	}
}

// MARK: - Source disclosure
extension CommunityCertificatesView {
	private var _sourceDisclosure: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				Label(.localized("Unofficial Source"), systemImage: "exclamationmark.shield")
					.font(.headline)
					.foregroundStyle(.orange)

				Text(
					verbatim: String.localized(
						"These certificates are not from Apple, from VexSign, or from a partner of either. They are published by a third party at %@, and everyone who uses this catalogue signs their apps with the same Apple Developer identity.",
						arguments: NexCerts.sourceHost
					)
				)
				.font(.callout)

				VStack(alignment: .leading, spacing: 10) {
					_disclosurePoint(
						.localized("The identity and its password are published together, so anyone can sign an app that claims to come from it.")
					)
					_disclosurePoint(
						.localized("Its owner can revoke it at any time. Every app you signed with it stops launching when they do.")
					)
					_disclosurePoint(
						.localized("Apple can revoke it for misuse, with the same effect.")
					)
					_disclosurePoint(
						.localized("VexSign downloads the files as they are. It can only check that the password opens the certificate.")
					)
				}

				Text(.localized("Fine for getting started. For anything you care about, import your own certificate instead."))
					.font(.footnote)
					.foregroundStyle(.secondary)

				VStack(spacing: 10) {
					Button {
						_acknowledge()
					} label: {
						Text(.localized("I Understand, Continue"))
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)

					if _isReviewingSource {
						Button(role: .destructive) {
							_turnOffSource()
						} label: {
							Text(.localized("Turn Off This Source"))
								.frame(maxWidth: .infinity)
						}
						.buttonStyle(.bordered)

						Button {
							_isReviewingSource = false
						} label: {
							Text(.localized("Back"))
								.frame(maxWidth: .infinity)
						}
						.buttonStyle(.borderless)
					}
				}
				.padding(.top, 4)
			}
			.padding()
		}
	}

	private func _disclosurePoint(_ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Image(systemName: "circle.fill")
				.font(.system(size: 5))
				.foregroundStyle(.secondary)

			Text(text)
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

// MARK: - Content
extension CommunityCertificatesView {
	private var _catalogList: some View {
		List {
			Section {
				ForEach(_catalogSections) { section in
					if section.isGroup {
						_groupRow(section)
					} else if let certificate = section.certificates.first {
						_certificateButton(certificate)
					}
				}
			} header: {
				Text(.localized("Unofficial · shared identity"))
			} footer: {
				Text(
					verbatim: String.localized(
						"Certificates, profiles and passwords are downloaded from %@. Everyone using this catalogue signs with the same identity.",
						arguments: NexCerts.sourceHost
					)
				)
			}

			Section {
				Button {
					_isReviewingSource = true
				} label: {
					HStack {
						Text(.localized("Source & Risks"))
						Spacer()
						Text(NexCerts.sourceHost)
							.foregroundStyle(.secondary)
						Image(systemName: "chevron.right")
							.font(.footnote.weight(.semibold))
							.foregroundStyle(.tertiary)
					}
				}
				.foregroundStyle(.primary)
			}
		}
		.listStyle(.insetGrouped)
		.disabled(_isImporting)
		.refreshable {
			await _loadCatalog(force: true)
		}
	}

	private var _loadingView: some View {
		VStack(spacing: 12) {
			ProgressView()
			Text(.localized("Fetching the community catalogue..."))
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding()
	}

	private func _errorView(message: String) -> some View {
		VStack(spacing: 14) {
			Image(systemName: "exclamationmark.triangle")
				.font(.largeTitle)
				.foregroundStyle(.orange)

			Text(.localized("Couldn't Load the Catalogue"))
				.font(.headline)

			Text(message)
				.font(.footnote)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)

			Button(.localized("Retry")) {
				Task {
					await _loadCatalog(force: true)
				}
			}
			.buttonStyle(.borderedProminent)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding()
	}
}

// MARK: - Rows
extension CommunityCertificatesView {
	@ViewBuilder
	private func _groupRow(_ section: NexCerts.CatalogSection) -> some View {
		DisclosureGroup(isExpanded: _groupExpansionBinding(for: section.id)) {
			ForEach(section.certificates) { certificate in
				_certificateButton(certificate)
			}
		} label: {
			_rowContent(
				title: section.title,
				subtitle: section.subtitle,
				statusText: section.status.title,
				status: section.status,
				isImporting: false
			)
		}
	}

	@ViewBuilder
	private func _certificateButton(_ certificate: NexCerts.CatalogItem) -> some View {
		Button {
			_pendingImport = certificate
		} label: {
			_rowContent(
				title: certificate.name,
				subtitle: certificate.subtitle,
				statusText: certificate.status.title,
				status: certificate.status,
				isImporting: _importingCertificateID == certificate.stringID
			)
		}
		.buttonStyle(.plain)
		.disabled(_isImporting)
	}

	private func _rowContent(
		title: String,
		subtitle: String?,
		statusText: String,
		status: NexCerts.Status,
		isImporting: Bool
	) -> some View {
		HStack(alignment: .center, spacing: 12) {
			VStack(alignment: .leading, spacing: 4) {
				Text(title)
					.font(.body.weight(.medium))
					.foregroundStyle(.primary)
					.multilineTextAlignment(.leading)

				if let subtitle, !subtitle.isEmpty {
					Text(subtitle)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.leading)
				}
			}

			Spacer(minLength: 12)

			if isImporting {
				ProgressView()
			} else {
				_statusBadge(text: statusText, status: status)
			}
		}
		.contentShape(Rectangle())
	}

	private func _statusBadge(text: String, status: NexCerts.Status) -> some View {
		let color = _statusColor(for: status)

		return Text(text)
			.font(.footnote.weight(.semibold))
			.foregroundStyle(color)
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(color.opacity(0.12), in: Capsule())
	}

	private func _statusColor(for status: NexCerts.Status) -> Color {
		switch status {
		case .signed:
			return .green
		case .revoked:
			return .red
		case .expired:
			return .yellow
		case .unknown:
			return .secondary
		}
	}
}

// MARK: - Actions
extension CommunityCertificatesView {
	@MainActor
	private func _loadCatalog(force: Bool = false) async {
		if _isLoading && !force {
			return
		}

		_isLoading = true
		_errorMessage = nil

		defer {
			_hasLoaded = true
			_isLoading = false
		}

		do {
			_catalogSections = try await NexCerts.fetchCatalog()
			_expandedGroups = []
		} catch {
			_catalogSections = []
			_errorMessage = error.localizedDescription
		}
	}

	@MainActor
	private func _import(_ certificate: NexCerts.CatalogItem) async {
		// The gate is the only path into this view's content, but re-check it:
		// nothing may be downloaded for a user who has not read the disclosure.
		guard _hasAcknowledged, NexCertsAccess.hasAcknowledged(), !_isImporting else { return }

		_isImporting = true
		_importingCertificateID = certificate.stringID

		defer {
			_importingCertificateID = nil
			_isImporting = false
		}

		do {
			try await NexCerts.importCertificate(certificate)
			dismiss()
		} catch {
			UIAlertController.showAlertWithOk(
				title: .localized("Error"),
				message: error.localizedDescription
			)
		}
	}

	private func _acknowledge() {
		NexCertsAccess.acknowledge()
		_isReviewingSource = false
		_hasAcknowledged = true
	}

	private func _turnOffSource() {
		NexCertsAccess.revoke()
		_pendingImport = nil
		_catalogSections = []
		_hasLoaded = false
		_hasAcknowledged = false
		dismiss()
	}

	private func _groupExpansionBinding(for id: String) -> Binding<Bool> {
		Binding {
			_expandedGroups.contains(id)
		} set: { isExpanded in
			if isExpanded {
				_expandedGroups.insert(id)
			} else {
				_expandedGroups.remove(id)
			}
		}
	}
}
