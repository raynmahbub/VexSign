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
    @EnvironmentObject var services: AppContainer
	@Environment(\.dismiss) private var dismiss
	
	@State private var _p12URL: URL?
	@State private var _provisionURL: URL?
	/// A single selection that may hold both files: a `.zip`, or a folder.
	@State private var _bundleURL: URL?
	@State private var _p12Password: String = ""
	@State private var _certificateName: String = ""
	@State private var _isSaving = false
	@State private var _showCracker: Bool = false
	
	var saveButtonDisabled: Bool {
		_isSaving || (_bundleURL == nil && (_p12URL == nil || _provisionURL == nil))
	}

	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("New Certificate"), displayMode: .inline) {
			Form {
				NBSection(.localized("Files")) {
					_importButton(.localized("Import Certificate Bundle"), file: _bundleURL) {
						// A shared certificate usually arrives as one `.zip` holding
						// cert.p12, its profile and often password.txt. Asking for the
						// two files separately failed for exactly that case.
						DocumentPicker.open([.zip, .p12, .mobileProvision], folder: .certificates) { urls in
							_bundleURL = urls.first
							// One selection replaces a stale half-pair, so the import
							// cannot silently mix files from two different certificates.
							if _bundleURL != nil { _p12URL = nil; _provisionURL = nil }
						}
					}
					Text(.localized("Choose the .p12, or a .zip / folder that contains the .p12 together with its .mobileprovision profile."))
						.font(.caption)
						.foregroundStyle(.secondary)
					Divider()
					_importButton(.localized("Import Certificate File"), file: _p12URL) {
						DocumentPicker.open([.p12], folder: .certificates) { urls in
							_p12URL = urls.first
							if _p12URL != nil { _bundleURL = nil }
						}
					}
					_importButton(.localized("Import Provisioning File"), file: _provisionURL) {
						DocumentPicker.open([.mobileProvision], folder: .certificates) { urls in
							_provisionURL = urls.first
							if _provisionURL != nil, _p12URL != nil { _bundleURL = nil }
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
		guard !_isSaving else { return }

		// The old guard reported a missing file as "check the password", which sent
		// people looking for a password problem that did not exist.
		if _bundleURL == nil {
			guard _p12URL != nil else {
				Toast.error(.localized("Choose the .p12 certificate first. It can be selected together with its profile as a .zip or folder."), duration: .sticky)
				return
			}
			guard _provisionURL != nil else {
				Toast.error(.localized("Choose the .mobileprovision profile that was issued with this certificate."), duration: .sticky)
				return
			}
		}

		_isSaving = true
		let finish: @MainActor (Error?) -> Void = { error in
			_isSaving = false
			if let error {
				Toast.error(error.localizedDescription, duration: .sticky)
				return
			}
			Toast.success(.localized("Certificate added"), systemImage: "checkmark.seal.fill")
			dismiss()
		}

		if let bundle = _bundleURL {
			services.certificates.importBundle(
				from: bundle,
				password: _p12Password,
				name: _certificateName,
				completion: finish
			)
			return
		}

		guard let p12URL = _p12URL, let provisionURL = _provisionURL else { return }
		services.certificates.importFiles(
			p12: p12URL,
			profile: provisionURL,
			password: _p12Password,
			name: _certificateName,
			completion: finish
		)
	}
}
