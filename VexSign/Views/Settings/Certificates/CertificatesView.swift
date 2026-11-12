//
//  CertificatesView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 15.04.2025.
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
    @ObservedObject private var migration = CredentialMigrationDiagnostics.shared
	@AppStorage("vexsign.selectedCert") private var _storedSelectedCert: Int = 0
	
	@State private var _addSheet: CertificateAddSheet?
	@State private var _isRenamingPresenting = false
	@State private var _isSelectedInfoPresenting: CertificatePair?
	@State private var _certToRename: CertificatePair?
	@State private var _newNickname: String = ""
	@State private var _isBatchChecking = false
	@State private var _isBatchCheckPresenting = false

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>

	private var _bindingSelectedCert: Binding<Int>?
	/// Set only when the list is used to pick a certificate for a specific app.
	private var _target: ProfileCompatibility.Target?
	private var _selectedCertBinding: Binding<Int> {
		_bindingSelectedCert ?? $_storedSelectedCert
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
			ForEach(Array(_certificates.enumerated()), id: \.element.uuid) { index, cert in
				_cellButton(for: cert, at: index)
			}
		}
		.navigationTitle(.localized("Certificates"))
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
			if _bindingSelectedCert == nil {
				ToolbarItemGroup(placement: .topBarTrailing) {
					if !_certificates.isEmpty {
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
		}
		.sheet(item: $_isSelectedInfoPresenting) { cert in
			CertificatesInfoView(cert: cert)
		}
		.sheet(isPresented: $_isBatchCheckPresenting) {
			BatchCertCheckView()
		}
		.sheet(item: $_addSheet) { sheet in
			_addSheetView(for: sheet)
		}
		.alert(.localized("Change Nickname"), isPresented: $_isRenamingPresenting, presenting: _certToRename) { cert in
			TextField(.localized("Nickname"), text: $_newNickname)
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("OK")) {
				cert.nickname = _newNickname.isEmpty ? nil : _newNickname
				Storage.shared.saveContext()
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
		let expiring = certs.filter {
			guard let date = $0.expiration else { return false }
			return date.timeIntervalSinceNow > 0 && date.timeIntervalSinceNow < 7 * 24 * 3600
		}.count
		let apps = Storage.shared.getAllApps().filter(\.isSigned).count

		VStack(alignment: .leading, spacing: 8) {
			Text(.localized("Certificate Health"))
				.font(.headline)
			HStack(spacing: 12) {
				_stat(.localized("%lld valid", arguments: certs.count - revoked), color: .green)
				if expiring > 0 { _stat(.localized("%lld expiring", arguments: expiring), color: .orange) }
				if revoked > 0 { _stat(.localized("%lld revoked", arguments: revoked), color: .red) }
			}
			Text(verbatim: .localized("%lld signed apps in the library use a certificate from this list.", arguments: apps))
				.font(.caption)
				.foregroundStyle(.secondary)
			Button(.localized("Check Revokage")) {
				for cert in certs { Storage.shared.revokagedCertificate(for: cert) }
				Toast.info(.localized("Checking certificates…"), systemImage: "person.text.rectangle")
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
	private func _cellButton(for cert: CertificatePair, at index: Int) -> some View {
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
	}
	
	@ViewBuilder
	private func _actions(for cert: CertificatePair) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			Storage.shared.deleteCertificate(for: cert)
		}
	}
	
	@ViewBuilder
	private func _contextActions(for cert: CertificatePair) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			Presentation.afterDismiss { _isSelectedInfoPresenting = cert }
		}
		Button(.localized("Change Nickname"), systemImage: "pencil") {
			_newNickname = cert.nickname ?? ""
			_certToRename = cert
			Presentation.afterDismiss { _isRenamingPresenting = true }
		}
		Button(.localized("Export Certificate"), systemImage: "square.and.arrow.up") {
            let workLease: AppOperationRegistry.Lease
            do { workLease = try AppOperationRegistry.shared.acquireTemporaryWork() }
            catch { Toast.error(error.localizedDescription); return }
            guard let zip = CertificateExporter.makeZip(for: cert) else {
                Toast.error(.localized("Couldn't export certificate"))
                return
            }
            guard let presenter = UIApplication.topViewController() else {
                do { try FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
                catch { FileLogger.error("Could not remove certificate export: \(error.localizedDescription)", category: "certificates") }
                Toast.error(.localized("Couldn't export certificate"))
                return
            }
            let controller = UIActivityViewController(activityItems: [zip], applicationActivities: nil)
            controller.completionWithItemsHandler = { _, _, _, _ in
                defer { withExtendedLifetime(workLease) {} }
                do { try FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
                catch { FileLogger.error("Could not remove certificate export: \(error.localizedDescription)", category: "certificates") }
            }
            if let popover = controller.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            presenter.present(controller, animated: true)
		}
		Divider()
		Button(.localized("Check Revocation (OCSP)"), systemImage: "checkmark.shield") {
			CertificateStatusManager.shared.refreshStatus(for: cert)
		}
		Button(.localized("Check Revokage"), systemImage: "person.text.rectangle") {
			Storage.shared.revokagedCertificate(for: cert)
		}
	}

	/// Runs the concurrent batch validation and shows the result table.
	private func _batchCheckCertificates() {
		guard !_isBatchChecking, !_certificates.isEmpty else { return }
		_isBatchChecking = true
		_isBatchCheckPresenting = true

		Task {
			await BatchCertChecker.shared.checkAll()

			let checked = BatchCertChecker.shared.results.count
			let valid = BatchCertChecker.shared.summary.valid
			_isBatchChecking = false

			Toast.success(
				String.localized("Checked %lld certificates — %lld valid", arguments: Int64(checked), Int64(valid)),
				systemImage: "checkmark.seal"
			)
		}
	}
}
