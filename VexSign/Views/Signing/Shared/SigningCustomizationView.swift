//
//  SigningCustomizationView.swift
//  VexSign
//
//  Created by VexSign Team
//

import SwiftUI
import PhotosUI
import NimbleViews
import NimbleExtensions

struct SigningCustomizationView: View {
	@State private var _isAltPickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _selectedPhoto: PhotosPickerItem?
	@State private var _displayedDescription: String?
	@State private var _originalInfoPlist: [String: Any] = [:]

	let app: AppInfoPresentable
	@Binding var options: Options
	@Binding var appIcon: UIImage?
	var identifierSuggestion: String?

	init(
		app: AppInfoPresentable,
		options: Binding<Options>,
		appIcon: Binding<UIImage?>,
		identifierSuggestion: String? = nil
	) {
		self.app = app
		self._options = options
		self._appIcon = appIcon
		self.identifierSuggestion = identifierSuggestion
		__displayedDescription = State(initialValue: app.appDescription)
	}

	// MARK: Body
	var body: some View {
		NBSection(.localized("Customization")) {
			Menu {
				Button(.localized("Select Alternative Icon"), systemImage: "app.dashed") {
					Presentation.afterDismiss { _isAltPickerPresenting = true }
				}
				Button(.localized("Choose from Files"), systemImage: "folder") {
					DocumentPicker.open([.image], folder: .icons) { urls in
						guard let url = urls.first else { return }
						appIcon = UIImage.fromFile(url)?.resizeToSquare()
					}
				}
				Button(.localized("Choose from Photos"), systemImage: "photo") {
					Presentation.afterDismiss { _isImagePickerPresenting = true }
				}
			} label: {
				if let appIcon {
					Image(uiImage: appIcon)
						.appIconStyle()
				} else {
					VexAppIconView(app: app, size: 56)
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) {
				NavigationStack {
					SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: true)
				}
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { _, newValue in
				guard let newValue else { return }

				Task {
					if
						let data = try? await newValue.loadTransferable(type: Data.self),
						let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}

			_infoCell(.localized("Name"), desc: options.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: options.appName ?? (app.name ?? ""),
					bindingValue: $options.appName
				)
			}
			_infoCell(.localized("Identifier"), desc: options.effectiveAppIdentifier ?? app.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: options.appIdentifier ?? (app.identifier ?? ""),
					bindingValue: $options.appIdentifier,
					suggestion: identifierSuggestion
				)
			}
			_infoCell(.localized("Version"), desc: options.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: options.appVersion ?? (app.version ?? ""),
					bindingValue: $options.appVersion
				)
			}
			LabeledContent(.localized("Minimum OS Version")) {
				Text(verbatim: (MergedInfoPlist(original: _originalInfoPlist, options: options)
					.effective["MinimumOSVersion"] as? String) ?? String.localized("Not declared or unavailable"))
			}
			Text(.localized("This is the planned Info.plist value, not a compatibility check. Lowering or removing it does not make unsupported apps work."))
				.font(.caption)
				.foregroundStyle(.secondary)
			NavigationLink {
				SigningDescriptionView(
					title: .localized("Description"),
					initialValue: _displayedDescription ?? "",
					onSave: { newValue in
						Storage.shared.updateDescription(for: app, description: newValue)
						_displayedDescription = newValue
					}
				)
			} label: {
				LabeledContent(.localized("Description")) {
					Text(verbatim: _displayedDescription ?? String.localized("None"))
						.lineLimit(1)
				}
			}
			.copyableText(_displayedDescription ?? "")
		}
		.task {
			guard let bundle = Storage.shared.getAppDirectory(for: app) else { return }
			do {
				let data = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
				_originalInfoPlist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
			} catch {
				// Metadata is advisory; never invent a minimum version on a read failure.
				_originalInfoPlist = [:]
			}
		}
	}

	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(verbatim: desc ?? String.localized("Unknown"))
			}
		}
	}
}
