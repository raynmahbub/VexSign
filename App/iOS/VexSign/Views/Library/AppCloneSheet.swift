//
//  AppCloneSheet.swift
//  VexSign
//
//  Duplicate an app in the library under a new name and bundle ID, so two copies
//  can run side by side (two accounts, a beta next to the release). The clone is
//  created unsigned and lands in the library ready to sign — signing is what gives
//  it an identity, and the certificate's profile has to allow the new identifier.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

struct AppCloneSheet: View {
	let app: AppInfoPresentable

	@Environment(\.dismiss) private var _dismiss

	@State private var _name: String = ""
	@State private var _bundleID: String = ""
	@State private var _isCloning = false
	@State private var _error: String?

	/// Prefix for the suggested identifier; keeps clones recognisable and valid.
	static let suggestedPrefix = "com.vexsign.cloned"

	var body: some View {
		NBNavigationView(.localized("Clone App"), displayMode: .inline) {
			Form {
				NBSection(.localized("Original")) {
					LabeledContent(.localized("Name"), value: app.name ?? .localized("Unknown"))
					LabeledContent(.localized("Identifier"), value: app.identifier ?? .localized("Unknown"))
					if let version = app.version {
						LabeledContent(.localized("Version"), value: version)
					}
				}

				NBSection(.localized("Clone")) {
					TextField(.localized("Name"), text: $_name)
						.disabled(_isCloning)

					TextField(.localized("Bundle Identifier"), text: $_bundleID)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.disabled(_isCloning)

					Button {
						_name = Self.suggestedName(for: app)
						_bundleID = Self.suggestedBundleID(for: app)
					} label: {
						Label(.localized("Reset to Suggestions"), systemImage: "arrow.counterclockwise")
					}
					.disabled(_isCloning)
				} footer: {
					Text(.localized("The clone is created unsigned. Sign it afterwards — the certificate's provisioning profile must allow the new bundle identifier, or use a wildcard profile."))
				}

				if let error = _error {
					Section {
						Text(error)
							.font(.footnote)
							.foregroundStyle(.red)
					}
				}

				Section {
					Button {
						_clone()
					} label: {
						HStack {
							Spacer()
							if _isCloning {
								ProgressView()
									.padding(.trailing, 6)
							}
							Label(.localized("Create Clone"), systemImage: "doc.on.doc")
								.bold()
							Spacer()
						}
					}
					.disabled(_isCloning || !_isValid)
				}
			}
			.toolbar {
				NBToolbarButton(role: .cancel)
			}
		}
		.interactiveDismissDisabled(_isCloning)
		.onAppear {
			if _name.isEmpty { _name = Self.suggestedName(for: app) }
			if _bundleID.isEmpty { _bundleID = Self.suggestedBundleID(for: app) }
		}
	}

	// MARK: Suggestions

	static func suggestedName(for app: AppInfoPresentable) -> String {
		"\(app.name ?? String.localized("App")) Copy"
	}

	/// `com.vexsign.cloned.<original>` — reverse-DNS, unique per source app.
	static func suggestedBundleID(for app: AppInfoPresentable) -> String {
		let base = app.originalIdentifier ?? app.identifier ?? "app"
		return "\(suggestedPrefix).\(base)"
	}

	/// Reverse-DNS shape, matching what `ClonePlan` accepts.
	static func isValidBundleID(_ value: String) -> Bool {
		value.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
	}

	private var _isValid: Bool {
		!_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& Self.isValidBundleID(_bundleID.trimmingCharacters(in: .whitespacesAndNewlines))
	}

	// MARK: Action

	private func _clone() {
		guard _isValid else {
			_error = .localized("Enter a name and a valid bundle identifier (for example com.example.app).")
			return
		}

		_isCloning = true
		_error = nil

		let name = _name.trimmingCharacters(in: .whitespacesAndNewlines)
		let bundleID = _bundleID.trimmingCharacters(in: .whitespacesAndNewlines)

		Task {
			do {
				let clone = try await AppCloner.shared.clone(
					app: app,
					customName: name,
					customBundleId: bundleID,
					asUnsigned: true
				)

				NBHaptic.tap()
				Toast.success(
					String.localized("Cloned %@. Sign it to install.", arguments: clone.name ?? name),
					systemImage: "doc.on.doc"
				)
				_isCloning = false
				_dismiss()
			} catch {
				_error = error.localizedDescription
				_isCloning = false
				Toast.error(error.localizedDescription, duration: .sticky)
			}
		}
	}
}
