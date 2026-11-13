//
//  ResetView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 19.06.2025.
//

import SwiftUI
import NimbleViews
import Nuke
import NimbleExtensions

// MARK: - View
struct ResetView: View {
	// MARK: Body
    var body: some View {
		NBList(.localized("Reset")) {
			_cache()
			_coredata()
			_all()
		}
    }
	
	private func _cacheSize() -> String {
		var totalCacheSize = URLCache.shared.currentDiskUsage
		if let nukeCache = ImagePipeline.shared.configuration.dataCache as? DataCache {
			totalCacheSize += nukeCache.totalSize
		}
		return "\(Int64(totalCacheSize).formattedFileSize)"
	}
	
	static func resetAlert(
		title: String,
		message: String = "",
		action: @escaping () -> Void
	) {
		DestructiveConfirm.present(title: title, message: message) {
			action()
			UIApplication.shared.suspendAndReopen()
		}
	}
}

// MARK: - View extension
extension ResetView {
	@ViewBuilder
	private func _cache() -> some View {
		Section {
			Button(.localized("Reset Work Cache"), systemImage: "xmark.rectangle.portrait") {
				Self.resetAlert(title: .localized("Reset Work Cache")) {
					Self.clearWorkCache()
				}
			}
			
			Button(.localized("Reset Network Cache"), systemImage: "xmark.rectangle.portrait") {
				Self.resetAlert(
					title: .localized("Reset Network Cache"),
					message: _cacheSize()
				) {
					Self.clearNetworkCache()
				}
			}
		}
	}
	
	@ViewBuilder
	private func _coredata() -> some View {
		Section {
			Button(.localized("Reset Sources"), systemImage: "xmark.circle") {
				Self.resetAlert(
					title: .localized("Reset Sources"),
					message: Storage.shared.countSources()
				) {
					Self.resetSources()
				}
			}
			
			Button(.localized("Reset Signed Apps"), systemImage: "xmark.circle") {
				Self.resetAlert(
					title: .localized("Reset Signed Apps"),
					message: Storage.shared.countSignedApps()
				) {
					Self.deleteSignedApps()
				}
			}
			
			Button(.localized("Reset Imported Apps"), systemImage: "xmark.circle") {
				Self.resetAlert(
					title: .localized("Reset Imported Apps"),
					message: Storage.shared.countImportedApps()
				) {
					Self.deleteImportedApps()
				}
			}

			Button(.localized("Reset Tweaks"), systemImage: "xmark.circle") {
				Self.resetAlert(
					title: .localized("Reset Tweaks"),
					message: .localized("%lld tweaks", arguments: TweakManager.shared.tweaks.count)
				) {
					Self.resetTweaks()
				}
			}

			Button(.localized("Reset Certificates"), systemImage: "xmark.circle") {
				Self.resetAlert(
					title: .localized("Reset Certificates"),
					message: Storage.shared.countCertificates()
				) {
					Self.resetCertificates()
				}
			}
		}
	}
	
	@ViewBuilder
	private func _all() -> some View {
		Section {
			Button(.localized("Reset Settings"), systemImage: "xmark.octagon") {
				Self.resetAlert(title: .localized("Reset Settings")) {
					Self.resetUserDefaults()
				}
			}
			
			Button(.localized("Reset All"), systemImage: "xmark.octagon") {
				Self.resetAlert(title: .localized("Reset All")) {
					Self.resetAll()
				}
			}
		}
		.foregroundStyle(.red)
	}
}

// MARK: - View extension: reset
extension ResetView {
	static func clearWorkCache() {
		StorageManager.purgeTemporary()
	}
	
	static func clearNetworkCache() {
		URLCache.shared.removeAllCachedResponses()
		HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
		
		if let dataCache = ImagePipeline.shared.configuration.dataCache as? DataCache {
			dataCache.removeAll()
		}
		
		if let imageCache = ImagePipeline.shared.configuration.imageCache as? Nuke.ImageCache {
			imageCache.removeAll()
		}
	}
	
	static func resetSources() {
		Storage.shared.clearSources()
	}
	
	static func deleteSignedApps() {
		Storage.shared.clearSignedApps()
	}
	
	static func deleteImportedApps() {
		Storage.shared.clearImportedApps()
	}

	static func resetTweaks() {
		TweakManager.shared.resetLibrary()
	}
	
	static func resetCertificates(resetAll: Bool = false) {
		Storage.shared.clearCertificates(resetSelection: !resetAll)
	}
	
	static func resetUserDefaults() {
		if let bundleID = Bundle.main.bundleIdentifier {
			UserDefaults.standard.removePersistentDomain(forName: bundleID)
		}
	}
	
	static func resetAll() {
		clearWorkCache()
		clearNetworkCache()
		resetSources()
		deleteSignedApps()
		deleteImportedApps()
		resetTweaks()
		resetCertificates(resetAll: true)
		resetUserDefaults()
	}
}
