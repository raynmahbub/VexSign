//
//  SigningAppPropertiesView.swift
//  VexSign
//
//  Created by VexSign Contributors on 17.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct SigningPropertiesView: View {
	@Environment(\.dismiss) var dismiss
	
	@State private var text: String = ""
	@State private var prefix: String = ""
	@State private var suffix: String = ""
	
	var saveButtonDisabled: Bool {
		text == initialValue && prefix.isEmpty && suffix.isEmpty
	}
	
	var title: String
	var initialValue: String
	@Binding var bindingValue: String?
	var suggestion: String?

	private var isIdentifier: Bool {
		title == .localized("Identifier")
	}

	// MARK: Body
	var body: some View {
		NBList(title) {
			Section {
				TextField(initialValue, text: $text)
					.textInputAutocapitalization(.none)
			}

			if isIdentifier {
				Section {
					HStack {
						TextField(.localized("Prefix"), text: $prefix)
							.textInputAutocapitalization(.none)
							.autocorrectionDisabled()
						Divider()
						TextField(.localized("Suffix"), text: $suffix)
							.textInputAutocapitalization(.none)
							.autocorrectionDisabled()
					}
					if !prefix.isEmpty || !suffix.isEmpty {
						Button(.localized("Apply to Identifier")) {
							text = "\(prefix)\(text)\(suffix)"
							prefix = ""
							suffix = ""
						}
					}
				} header: {
					Text(verbatim: .localized("Prefix & Suffix"))
				} footer: {
					Text(.localized("Add a custom prefix or suffix to ensure unique bundle IDs when cloning or testing apps."))
				}
			}

			if let suggestion, suggestion != text {
				Section {
					Button {
						text = suggestion
					} label: {
						Label(.localized("Match Certificate Identifier"), systemImage: "checkmark.seal")
					}
				} footer: {
					Text(verbatim: .localized("Use %@ from your selected provisioning profile.", arguments: suggestion))
				}
			}
		}
		.dismissableKeyboard()
		.toolbar {
			NBToolbarButton(
				.localized("Save"),
				style: .text,
				placement: .topBarTrailing,
				isDisabled: saveButtonDisabled
			) {
				if !saveButtonDisabled {
					var result = text
					if !prefix.isEmpty || !suffix.isEmpty {
						result = "\(prefix)\(result)\(suffix)"
					}
					bindingValue = result
					dismiss()
				}
			}
		}
		.onAppear {
			text = initialValue
		}
	}
}
