//
//  CertificatesAddView.swift
//  VexSign
//
//  Created by VexSign Contributors on 15.04.2025.
//

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers
import NimbleExtensions

// MARK: - View
struct CertificatesAddView: View {
	@Environment(\.dismiss) private var dismiss
	
	@State private var _p12URL: URL?
	@State private var _provisionURL: URL?
	@State private var _p12Password: String = ""
	@State private var _certificateName: String = ""
	@State private var _isSaving = false
	@State private var _showCracker: Bool = false
	
	var saveButtonDisabled: Bool {
		_isSaving || _p12URL == nil || _provisionURL == nil
	}
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("New Certificate"), displayMode: .inline) {
			Form {
				NBSection(.localized("Files")) {
					_importButton(.localized("Import Certificate File"), file: _p12URL) {
						DocumentPicker.open([.p12], folder: .certificates) { urls in
							_p12URL = urls.first
						}
					}
					_importButton(.localized("Import Provisioning File"), file: _provisionURL) {
						DocumentPicker.open([.mobileProvision], folder: .certificates) { urls in
							_provisionURL = urls.first
						}
					}
				}
				NBSection(.localized("Password")) {
					SecureField(.localized("Enter Password"), text: $_p12Password)

					if let _ = _p12URL {
						Button {
							_showCracker = true
						} label: {
							Label(.localized("Recover / Find Password"), systemImage: "key.viewfinder")
								.font(.footnote)
						}
					}
				} footer: {
					Text(.localized("Enter the password associated with the private key. Leave it blank if theres no password required."))
				}
				
				Section {
					TextField(.localized("Nickname (Optional)"), text: $_certificateName)
				}
			}
			.disabled(_isSaving)
			.interactiveDismissDisabled(_isSaving)
			.dismissableKeyboard()
			.sheet(isPresented: $_showCracker) {
				if let p12URL = _p12URL {
					P12CrackerView(p12URL: p12URL) { recovered in
						_p12Password = recovered
						Toast.success(.localized("Password recovered!"), systemImage: "checkmark.seal.fill")
					}
				}
			}
			.toolbar {
				NBToolbarButton(
					.localized("Cancel"), systemImage: "xmark",
					placement: .cancellationAction, isDisabled: _isSaving
				) { dismiss() }
				
				NBToolbarButton(
					.localized("Save"),
					style: .text,
					placement: .confirmationAction,
					isDisabled: saveButtonDisabled
				) {
					_saveCertificate()
				}
			}
		}
	}
}

// MARK: - Extension: View
extension CertificatesAddView {
	@ViewBuilder
	private func _importButton(
		_ title: String,
		file: URL?,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			HStack {
				VStack(alignment: .leading, spacing: 4) {
					Text(title)
					if let file {
						Text(file.lastPathComponent)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Spacer()
				if file != nil { Image(systemName: "checkmark.circle.fill") }
			}
		}
		.foregroundColor(.accentColor)
		.accessibilityValue(file?.lastPathComponent ?? "")
		.animation(.easeInOut(duration: 0.3), value: file != nil)
	}
}

// MARK: - Extension: View (import)
extension CertificatesAddView {
	private func _saveCertificate() {
		guard
			let p12URL = _p12URL,
			let provisionURL = _provisionURL,
			!_isSaving
		else {
			Toast.error(.localized("Please check the password and try again."), duration: .sticky)
			return
		}

		_isSaving = true
		CertificateManagementService.importCertificateFiles(
			p12URL: p12URL,
			provisionURL: provisionURL,
			p12Password: _p12Password,
			certificateName: _certificateName
		) { error in
			_isSaving = false
			if let error {
				Toast.error(error.localizedDescription, duration: .sticky)
				return
			}
			Toast.success(.localized("Certificate added"), systemImage: "checkmark.seal.fill")
			dismiss()
		}
	}
}
