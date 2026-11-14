//
//  BackupComponentsView.swift
//  VexSign
//
//  Created by VexSign Team
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct BackupComponentsView: View {
	@Environment(\.dismiss) private var dismiss

	let title: String
	let confirmTitle: String
	let available: BackupComponents
	var counts: [BackupComponents: Int] = [:]
	var detail: String?
	let footer: String
	var passwordFooter: String?
	/// When true, the certificates component cannot be included without a
	/// password long enough to be worth deriving a key from.
	var enforcesPasswordForCertificates: Bool = false
	let onConfirm: (BackupComponents, String) -> Void

	@State private var _selection: BackupComponents
	@State private var _password = ""
	@State private var _confirmation = ""
	@State private var _showPasswordNotice = false

	init(
		title: String,
		confirmTitle: String,
		available: BackupComponents,
		counts: [BackupComponents: Int] = [:],
		detail: String? = nil,
		footer: String,
		passwordFooter: String? = nil,
		enforcesPasswordForCertificates: Bool = false,
		onConfirm: @escaping (BackupComponents, String) -> Void
	) {
		self.title = title
		self.confirmTitle = confirmTitle
		self.available = available
		self.counts = counts
		self.detail = detail
		self.footer = footer
		self.passwordFooter = passwordFooter
		self.enforcesPasswordForCertificates = enforcesPasswordForCertificates
		self.onConfirm = onConfirm
		__selection = State(initialValue: available)
	}

	// MARK: Body
	var body: some View {
		NBNavigationView(title, displayMode: .inline) {
			Form {
				NBSection(.localized("Include")) {
					ForEach(BackupComponents.ordered.filter { available.contains($0) }, id: \.rawValue) { component in
						Toggle(isOn: _binding(component)) {
							HStack {
								Label(component.title, systemImage: component.icon)
								Spacer()
								if let count = counts[component] {
									Text(verbatim: "\(count)")
										.foregroundStyle(.secondary)
								}
							}
						}
					}

					Button(.localized("Select All")) {
						_selection = available
					}
					.disabled(_selection == available)
				} footer: {
					VStack(alignment: .leading, spacing: 6) {
						if let detail {
							Text(verbatim: detail)
						}
						Text(footer)
					}
				}

				if let passwordFooter {
					NBSection(.localized("Password")) {
						SecureField(.localized("Password"), text: $_password)
						if enforcesPasswordForCertificates {
							SecureField(.localized("Confirm Password"), text: $_confirmation)
						}
					} footer: {
						VStack(alignment: .leading, spacing: 6) {
							Text(passwordFooter)
							if _needsPasswordForCertificates {
								Label(
									String.localized("Use at least %lld characters, typed the same twice, to include certificates.", arguments: Int64(BackupCrypto.minimumPasswordLength)),
									systemImage: "exclamationmark.triangle.fill"
								)
								.foregroundStyle(.orange)
								.font(.footnote)
							}
						}
					}
				}
			}
			.dismissableKeyboard()
			.toolbar {
				NBToolbarButton(role: .cancel)

				NBToolbarButton(
					confirmTitle,
					style: .text,
					placement: .confirmationAction,
					isDisabled: _selection.isEmpty || _needsPasswordForCertificates
				) {
					onConfirm(_selection, _password)
					dismiss()
				}
			}
		}
		.alert(.localized("Password needed"), isPresented: $_showPasswordNotice) {
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(verbatim: String.localized("A backup that includes certificates contains private keys, so it is only written with a password of at least %lld characters.", arguments: Int64(BackupCrypto.minimumPasswordLength)))
		}
	}

	private func _binding(_ component: BackupComponents) -> Binding<Bool> {
		Binding(
			get: { _selection.contains(component) },
			set: { isOn in
				if isOn {
					guard !(enforcesPasswordForCertificates && component == .certificates && !_passwordIsUsable) else {
						_showPasswordNotice = true
						return
					}
					_selection.insert(component)
				} else {
					_selection.remove(component)
				}
			}
		)
	}

	/// A backup with certificates carries private keys, so it needs a password of
	/// real length, typed the same way twice.
	private var _passwordIsUsable: Bool {
		_password.count >= BackupCrypto.minimumPasswordLength && _password == _confirmation
	}

	private var _needsPasswordForCertificates: Bool {
		enforcesPasswordForCertificates && _selection.contains(.certificates) && !_passwordIsUsable
	}
}
