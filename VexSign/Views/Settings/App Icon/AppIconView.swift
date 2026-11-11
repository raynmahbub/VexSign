//
//  AppIconView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 19.06.2025.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View extension: Model
extension AppIconView {
	struct AltIcon: Identifiable {
		var displayName: String
		var author: String
		var key: String?
		var image: UIImage
		var id: String { key ?? displayName }

		init(displayName: String, author: String, key: String? = nil) {
			self.displayName = displayName
			self.author = author
			self.key = key
			self.image = altImage(key)
		}
	}

	static func altImage(_ name: String?) -> UIImage {
		if name == nil, let logo = UIImage(named: "AppLogo") { return logo }
		let path = Bundle.main.bundleURL.appendingPathComponent((name ?? "AppIcon60x60") + "@2x.png")
		return UIImage(contentsOfFile: path.path) ?? UIImage(named: "AppLogo") ?? UIImage()
	}
}

// MARK: - View
struct AppIconView: View {
	@Binding var currentIcon: String?

	// These names are not translated. Decode icon previews once instead of every
	// time SwiftUI reconstructs the settings view.
	private static let sections: [String: [AltIcon]] = [
		"Main": [
			AltIcon(displayName: "Liquid Glass", author: "VexSign", key: nil),
			AltIcon(displayName: "VexSign (macOS)", author: "claration", key: "V2Mac"),
			AltIcon(displayName: "VexSign v1", author: "claration", key: "V1"),
			AltIcon(displayName: "VexSign v1 (macOS)", author: "claration", key: "V1Mac"),
			AltIcon(displayName: "VexSign v0", author: "claration", key: "V0"),
			AltIcon(displayName: "VexSign Donor", author: "claration", key: "Donor")
		],
		"Wingio": [
			AltIcon(displayName: "VexSign", author: "Wingio", key: "Wing")
		]
	]

	// MARK: Body
	var body: some View {
		NBList(.localized("App Icon")) {
			ForEach(Self.sections.keys.sorted(), id: \.self) { section in
				if let icons = Self.sections[section] {
					NBSection(section) {
						ForEach(icons) { icon in
							_icon(icon: icon)
						}
					}
				}
			}
		}
		.onAppear {
			currentIcon = UIApplication.shared.alternateIconName
		}
	}
}

// MARK: - View extension
extension AppIconView {
	@ViewBuilder
	private func _icon(
		icon: AppIconView.AltIcon
	) -> some View {
		Button {
			UIApplication.shared.setAlternateIconName(icon.key) { error in
                Task { @MainActor in
                    if let error { Toast.error(error.localizedDescription); return }
                    UserDefaults.standard.set(icon.key ?? "", forKey: "VexSign.selectedAppIcon")
                    FRIconCache.shared.invalidateAll()
                    currentIcon = UIApplication.shared.alternateIconName
                }
			}
		} label: {
			HStack(spacing: 18) {
				Image(uiImage: icon.image)
					.appIconStyle()

				NBTitleWithSubtitleView(
					title: icon.displayName,
					subtitle: icon.author,
					linelimit: 0
				)

				if currentIcon == icon.key {
					Image(systemName: "checkmark").bold()
				}
			}
		}
	}
}
