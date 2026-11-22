//
//  CertificatesView.swift
//  VexSign
//
//  Created by VexSign Contributors on 15.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

private enum CertificateAddSheet: String, Identifiable {
	case certificateFiles
	case community

	var id: String { rawValue }
}

// MARK: - View
struct CertificatesView: View {
	@EnvironmentObject private var appContainer: AppContainer
    @ObservedObject private var migration = CredentialMigrationDiagnostics.shared
	@AppStorage("vexsign.selectedCert") private var _storedSelectedCert: Int = 0
	@State private var _coordinator: CertificatesViewCoordinator?

	@State private var _addSheet: CertificateAddSheet?
	@State private var _isRenamingPresenting = false
	@State private var _isSelectedInfoPresenting: CertificateRecord?
	@State private var _certToRename: CertificateRecord?
	@State private var _newNickname: String = ""
	@State private var _isBatchChecking = false
	@State private var _isBatchCheckPresenting = false
	/// The certificate a delete was requested for. Nothing is removed until it is confirmed:
	/// the private key goes with it and cannot be recovered from VexSign afterwards.
	@State private var _certPendingDeletion: CertificateRecord?
	@State private var _isDeleteConfirmationPresenting = false
    @State private var _revealedCertificateID: String?

	// MARK: Fetch
	@WorkspaceQuery(\.certificates, order: .newestFirst) private var _certificates: [CertificateRecord]

	private var _bindingSelectedCert: Binding<Int>?
	/// Set only when the list is used to pick a certificate for a specific app.
	private var _target: ProfileCompatibility.Target?
	private var _selectedCertBinding: Binding<Int> {
		_bindingSelectedCert ?? $_storedSelectedCert
	}

	private var coordinator: CertificatesViewCoordinator {
		_coordinator ?? appContainer.makeCertificatesCoordinator()
	}

	init(selectedCert: Binding<Int>? = nil, target: ProfileCompatibility.Target? = nil) {
		self._bindingSelectedCert = selectedCert
		self._target = target
	}

	// MARK: Body
	var body: some View {
		NBGrid {
            ForEach(migration.warnings, id: \.self) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

			if !_certificates.isEmpty {
				_healthHeader
			}
			ForEach(Array(_certificates.enumerated()), id: \.element.id) { index, cert in
				_cellButton(for: cert, at: index)
			}
		}
		.navigationTitle(.localized("Certificates"))
		.onAppear {
			if _coordinator == nil {
				_coordinator = appContainer.makeCertificatesCoordinator()
			}
			// Keep the shared schedule current with the list the user is looking at.
			RenewalSchedulePresentation.refresh(records: Array(_certificates))
		}
		.onChange(of: _certificates) { _, certificates in
			RenewalSchedulePresentation.refresh(records: Array(certificates))
		}
		.overlay {
			if _certificates.isEmpty && migration.warnings.isEmpty {
				NBContentUnavailable(
					.localized("No Certificates"),
					systemImage: "questionmark.folder.fill",
					description: .localized("Get started signing by importing your first certificate.")
				) {
					Menu {
						_addOptions()
					} label: {
						NBButton(.localized("Import"), style: .text)
					}
				}
			}
		}
		.toolbar {
                // The app-specific picker must also offer import; otherwise a
                // profile mismatch strands the user in a list they cannot fix.
				ToolbarItemGroup(placement: .topBarTrailing) {
					if _bindingSelectedCert == nil && !_certificates.isEmpty {
						Button {
							_batchCheckCertificates()
						} label: {
							if _isBatchChecking {
								ProgressView()
							} else {
								Image(systemName: "arrow.triangle.2.circlepath")
							}
						}
						.disabled(_isBatchChecking)
					}

					Menu {
						_addOptions()
					} label: {
						Image(systemName: "plus")
					}
				}
		}
		.sheet(item: $_isSelectedInfoPresenting) { cert in
			CertificatesInfoView(cert: cert)
		}
		.sheet(isPresented: $_isBatchCheckPresenting) {
			BatchCertCheckView()
		}
		.undoableRemovalBanner()
		.sheet(item: $_addSheet) { sheet in
			_addSheetView(for: sheet)
		}
		.confirmationDialog(
			.localized("Delete this certificate?"),
			isPresented: $_isDeleteConfirmationPresenting,
			titleVisibility: .visible,
			presenting: _certPendingDeletion
		) { cert in
			Button(.localized("Delete Certificate"), role: .destructive) {
				// The dialog is dismissed by the tap, so a second tap cannot arrive; the
				// pending value is cleared as well so nothing can replay it.
				_certPendingDeletion = nil
				coordinator.deleteCertificate(cert)
			}
			Button(.localized("Cancel"), role: .cancel) { _certPendingDeletion = nil }
		} message: { _ in
			Text(.localized("The certificate, its private key and its provisioning profile are removed from VexSign. It is not revoked with Apple, and apps already signed with it are not changed. Saved signing settings that use it will fall back to the selected certificate, and any automatic signing approved for it stops."))
		}
		.alert(.localized("Change Nickname"), isPresented: $_isRenamingPresenting, presenting: _certToRename) { cert in
			TextField(.localized("Nickname"), text: $_newNickname)
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("OK")) {
				coordinator.renameCertificate(cert, to: _newNickname)
			}
		}
	}
}

// MARK: - View extension
extension CertificatesView {
	@ViewBuilder
	private func _addOptions() -> some View {
		Button(.localized("Community Certificates (Unofficial)")) {
			_addSheet = .community
		}

		Button(.localized("Certificate Files")) {
			_addSheet = .certificateFiles
		}
	}

	@ViewBuilder
	private func _addSheetView(for sheet: CertificateAddSheet) -> some View {
		switch sheet {
		case .certificateFiles:
			CertificatesAddView()
				.presentationDetents([.medium])
		case .community:
			CommunityCertificatesView()
				.presentationDetents([.large])
		}
	}

	@ViewBuilder
	private var _healthHeader: some View {
		let certs = Array(_certificates)
		let revoked = certs.filter { $0.revoked }.count
		// One definition of "expiring", shared with the row pill and the background pass.
		// The previous inline `expiration < 7 days` check disagreed with both: it ignored
		// the leaf certificate's earlier date and counted credentials this build cannot
		// renew as if a renewal were pending.
		let credentials = RenewalSchedulePresentation.credentials(from: certs)
		let expiring = credentials
			.map { RenewalPlanner.plan(for: $0) }
			.filter { $0.status == .due || $0.status == .urgent || $0.status == .lapsed }
			.count
		// Revoked rows are excluded: they are already counted as revoked above, and their
		// remedy is replacement, not renewal.
		let unrenewable = credentials.filter { !$0.canRenewOnDevice && !$0.isRevoked }.count
		let apps = coordinator.signedAppsCount()

		VStack(alignment: .leading, spacing: 8) {
			Text(.localized("Certificate Health"))
				.font(.headline)
			HStack(spacing: 12) {
				_stat(.localized("%lld valid", arguments: certs.count - revoked), color: .green)
				if expiring > 0 { _stat(.localized("%lld expiring", arguments: expiring), color: .orange) }
				if revoked > 0 { _stat(.localized("%lld revoked", arguments: revoked), color: .red) }
			}
			// Said once, in plain words, instead of leaving a countdown the user cannot act
			// on. Native Apple Account signing is not integrated in this build, so a free
			// Account profile can be seen expiring but not renewed here.
			if unrenewable > 0 && !NativeRenewalCapability.isAvailable {
				Text(.localized("VexSign cannot renew these certificates for you. Replace the certificate or re-sign affected apps with one you import."))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Text(verbatim: .localized("%lld signed apps in the library use a certificate from this list.", arguments: apps))
				.font(.caption)
				.foregroundStyle(.secondary)
			Button(.localized("Check Revokage")) {
				coordinator.checkRevokage(for: certs)
			}
			.font(.subheadline.weight(.semibold))
		}
		.padding()
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .quaternarySystemFill)))
	}

	private func _stat(_ title: String, color: Color) -> some View {
		Text(title)
			.font(.caption.weight(.semibold))
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(color.opacity(0.15), in: Capsule())
			.foregroundStyle(color)
	}

	@ViewBuilder
	private func _cellButton(for cert: CertificateRecord, at index: Int) -> some View {
		let cornerRadius = NBRadius.large

		Button {
			_selectedCertBinding.wrappedValue = index
		} label: {
			CertificatesCellView(
				cert: cert,
				target: _target
			)
			.padding()
			.background(
				RoundedRectangle(cornerRadius: cornerRadius)
					.fill(Color(uiColor: .quaternarySystemFill))
			)
			.overlay(
				RoundedRectangle(cornerRadius: cornerRadius)
					.strokeBorder(
						_selectedCertBinding.wrappedValue == index ? Color.accentColor : Color.clear,
						lineWidth: 2
					)
			)
			.contextMenu {
				_contextActions(for: cert)
				Divider()
				_actions(for: cert)
			}
			.transaction {
				$0.animation = nil
			}
		}
		.buttonStyle(.plain)
		// Cards are not List rows, so the card swipe the Library grid uses reveals Delete.
		// It only asks: the confirmation below is what removes anything.
        .modifier(LibraryGridSwipeDelete(enabled: true, rowID: cert.id, revealedRowID: $_revealedCertificateID) {
			_certPendingDeletion = cert
			_isDeleteConfirmationPresenting = true
		})
		.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
	}

	@ViewBuilder
	private func _actions(for cert: CertificateRecord) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			Presentation.afterDismiss {
				_certPendingDeletion = cert
				_isDeleteConfirmationPresenting = true
			}
		}
	}

	@ViewBuilder
	private func _contextActions(for cert: CertificateRecord) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			Presentation.afterDismiss { _isSelectedInfoPresenting = cert }
		}
		Button(.localized("Change Nickname"), systemImage: "pencil") {
			_newNickname = cert.nickname ?? ""
			_certToRename = cert
			Presentation.afterDismiss { _isRenamingPresenting = true }
		}
		Button(.localized("Export Certificate"), systemImage: "square.and.arrow.up") {
			coordinator.exportCertificate(cert)
		}
		Divider()
		Button(.localized("Check Revocation (OCSP)"), systemImage: "checkmark.shield") {
			coordinator.refreshOCSPStatus(for: cert)
		}
		Button(.localized("Check Revokage"), systemImage: "person.text.rectangle") {
			coordinator.checkRevokage(for: cert)
		}
	}

	/// Runs the concurrent batch validation and shows the result table.
	private func _batchCheckCertificates() {
		guard !_isBatchChecking, !_certificates.isEmpty else { return }
		_isBatchChecking = true
		Task { @MainActor in
			await coordinator.runBatchCheckAsync {
				_isBatchCheckPresenting = true
			}
			_isBatchChecking = false
		}
	}
}
