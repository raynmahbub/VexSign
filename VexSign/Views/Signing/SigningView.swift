//
//  SigningView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 14.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isSigning = false
	@State private var _isLogPresenting = false
	@State private var _postSignAction: (() -> Void)? = nil
	@State var appIcon: UIImage?
	@AppStorage("VexSign.autoShowSigningLogs") private var _autoShowLogs: Bool = false

	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}

	private func _provisioningIdentifier() -> String? {
		guard
			let cert = _selectedCert(),
			let decoded = Storage.shared.getProvisionFileDecoded(for: cert),
			let appId = decoded.Entitlements?["application-identifier"]?.value as? String
		else {
			return nil
		}

		let bundleId = appId.drop { $0 != "." }.dropFirst()
		guard !bundleId.isEmpty, !bundleId.contains("*") else { return nil }
		return String(bundleId)
	}
	
	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable) {
		self.app = app
		let storedCert = UserDefaults.standard.integer(forKey: "vexsign.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	/// What the certificate picker compares against: the app as the current options will leave it.
	private var _compatibilityTarget: ProfileCompatibility.Target {
		let nested = Storage.shared.getAppDirectory(for: app)
			.map {
				NestedBundleAudit.requiredIdentifiers(
					in: $0,
					removeAppExtensions: _temporaryOptions.removeAppExtensions
				)
			} ?? []
		return ProfileCompatibility.Target(
			app: app,
			options: _temporaryOptions,
			nestedBundleIdentifiers: nested
		)
	}

	// MARK: Body
    var body: some View {
		NBNavigationView("", displayMode: .inline) {
			ScrollViewReader { proxy in
				Form {
					SigningCustomizationView(
						app: app,
						options: $_temporaryOptions,
						appIcon: $appIcon,
						identifierSuggestion: _provisioningIdentifier()
					)
					_cert()
					SigningAdvancedView(
						app: app,
						options: $_temporaryOptions,
						certificate: _selectedCert(),
						scrollProxy: proxy
					)

					// horrible
					Rectangle()
						.foregroundStyle(.clear)
						.frame(height: 30)
						.listRowBackground(EmptyView())
				}
			}
			.disabled(_isSigning)
			.animation(.smooth, value: _isSigning)
			.overlay {
				VStack(spacing: 0) {
					Spacer()
					NBVariableBlurView()
						.frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 60 : 80)
						.rotationEffect(.degrees(180))
						.overlay {
							HStack(spacing: 12) {
								if _isSigning {
									Button {
										_stopSigning()
									} label: {
										Image(systemName: "stop.fill")
											.font(.headline)
											.foregroundStyle(.red)
											.frame(width: 46, height: 46)
											.background(.ultraThinMaterial, in: Circle())
									}
									.buttonStyle(.plain)
									.accessibilityLabel(.localized("Stop Signing"))
									.accessibilityIdentifier(A11y.Signing.stop)
									.transition(.scale.combined(with: .opacity))
								}

									Button {
										if _isSigning {
											_isLogPresenting = true
										} else {
											_start()
										}
									} label: {
										NBSheetButton(title: .localized(_isSigning ? "Show Logs" : "Start Signing"), style: .prominent)
											.overlay(alignment: .trailing) {
												if _isSigning {
													ProgressView()
														.progressViewStyle(.circular)
														.tint(.white)
														.padding(.trailing, 28)
														.allowsHitTesting(false)
														.accessibilityIdentifier(A11y.Signing.progress)
												}
											}
											.padding()
									}
									.buttonStyle(.plain)
									.accessibilityIdentifier(A11y.Signing.start)
								}
							.offset(y: UIDevice.current.userInterfaceIdiom == .pad ? -20 : -40)
							.animation(.smooth, value: _isSigning)
						}
				}
				.ignoresSafeArea(edges: .bottom)
			}

			.toolbar {
				NBToolbarButton(role: .dismiss)
				ToolbarItem(placement: .principal) {
					Image("Glyph")
						.resizable()
						.scaledToFit()
						.frame(height: 38)
						.foregroundStyle(.primary)
				}
				ToolbarItemGroup(placement: .topBarTrailing) {
					Menu {
						Button {
							dismiss()
							InstallQueue.shared.enqueue(app)
						} label: {
							Label(.localized("Install Without Signing"), systemImage: "bolt.badge.checkmark")
						}

						Divider()

						Button(.localized("Reset")) {
							_temporaryOptions = OptionsManager.shared.options
							_temporaryOptions.resetPerApp(for: app)
							appIcon = nil
						}
						if !NamedSigningProfileStore.shared.profiles.isEmpty {
							Section(.localized("Apply Profile")) {
								ForEach(NamedSigningProfileStore.shared.profiles) { profile in
									Button(profile.name) {
										_temporaryOptions = profile.options.resolved(for: app)
										if let uuid = profile.certificateUUID,
										   let index = certificates.firstIndex(where: { $0.uuid == uuid }) {
											_temporaryCertificate = index
										}
									}
								}
							}
						}
						Button(.localized("Save as Named Profile")) {
							let name = app.name ?? .localized("Profile")
							NamedSigningProfileStore.shared.save(NamedSigningProfile(
								name: name,
								options: _temporaryOptions,
								certificateUUID: _selectedCert()?.uuid
							))
							Toast.success(.localized("Saved profile"), systemImage: "person.crop.rectangle.stack")
						}
					} label: {
						Image(systemName: "ellipsis.circle")
					}
				}
			}
			.sheet(isPresented: $_isLogPresenting, onDismiss: {
				_postSignAction?()
				_postSignAction = nil
			}) {
				SigningLogView()
				.accessibilityIdentifier(A11y.Signing.console)
					.presentationDetents([.medium, .large])
					.presentationDragIndicator(.visible)
			}
		}
		.onAppear { _temporaryOptions = _temporaryOptions.resolved(for: app) }
		.onDisappear { UIApplication.shared.endEditing() }
    }
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate, target: _compatibilityTarget)
				} label: {
					CertificatesCellView(
						cert: cert,
						target: _compatibilityTarget
					)
				}
			} else {
				Text(.localized("No Certificate"))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		}
	}
	
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start() {
		guard
			_selectedCert() != nil || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		NBHaptic.tap()

		// Preflight: catch bundle id, plist, dylib and certificate problems before the long sign.
		let preflight = PreflightChecks.run(
			app: app,
			options: _temporaryOptions,
			certificate: _selectedCert()
		)
		if preflight.hasBlocking {
			let lines = preflight.issues
				.filter { $0.severity == .blocking }
				.map { "• \($0.title): \($0.detail)" }
				.joined(separator: "\n")
			UIAlertController.showAlertWithOptions(
				title: .localized("Check Before Signing"),
				message: lines,
				actions: [
					(.localized("Sign Anyway"), .destructive, {
						_beginSign()
					}),
					(.localized("Cancel"), .cancel, nil)
				]
			)
			return
		} else if !preflight.issues.isEmpty {
			let lines = preflight.issues
				.map { "• \($0.title): \($0.detail)" }
				.joined(separator: "\n")
			UIAlertController.showAlertWithOptions(
				title: .localized("Warnings"),
				message: lines,
				actions: [
					(.localized("Sign"), .default, {
						_beginSign()
					}),
					(.localized("Cancel"), .cancel, nil)
				]
			)
			return
		}

		_beginSign()
	}

	/// Stops the run in flight. The pipeline notices between stages (and inside the long bundle
	/// walk), removes everything it copied, and reports back as cancelled — so the sheet stays
	/// usable and nothing half-signed is left in the library.
	private func _stopSigning() {
		SigningService.shared.cancelAll()
	}

	private func _beginSign() {
		_isSigning = true
		if _autoShowLogs { _isLogPresenting = true }

		FR.signPackageFile(
			app,
			using: _temporaryOptions,
			icon: appIcon,
			certificate: _selectedCert()
		) { result in
			switch result {
			case .failure(let error):
				// Keep the sheet open so the user can fix and retry.
				_isSigning = false

				if error is CancellationError {
					// Stopping on purpose is not a failure, and the run has already cleaned up
					// after itself — say so quietly instead of showing an error the user caused.
					Toast.info(.localized("Signing cancelled"), systemImage: "stop.circle")
				} else {
					Toast.error(error.localizedDescription, duration: .sticky)
				}
			case .success(let signed):
				_isSigning = false
				Toast.success(.localized("Signed successfully"), systemImage: "checkmark.seal.fill")

				// Remember the exact settings + certificate so "Re-sign with last settings"
				// and Update All can reproduce this identity later.
				SigningProfileStore.shared.capture(
					options: _temporaryOptions,
					certificate: _selectedCert(),
					for: app
				)

				let finish = {
					let deletesSource = _temporaryOptions.post_deleteAppAfterSigned && !app.isSigned

					if deletesSource {
						Storage.shared.deleteApp(for: app)
					}

					// Auto cleanup: honours Delete Unsigned / Signed App and the storage toggles.
					// Runs after the deletion above so it never reads a removed object.
					let remainingSource: AppInfoPresentable? = deletesSource ? nil : app
					CleanupManager.shared.runAfterSign(
						source: remainingSource,
						signed: signed,
						keepsSignedApp: _temporaryOptions.post_installAppAfterSigned
					)

					if _temporaryOptions.post_installAppAfterSigned {
						InstallQueue.shared.enqueue(signed)
					}

					dismiss()
				}

				// If the user is watching logs, hold the finish until they close the console.
				if _isLogPresenting {
					_postSignAction = finish
				} else {
					finish()
				}
			}
		}
	}
}
