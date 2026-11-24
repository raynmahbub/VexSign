//
//  AppExtensionEnumerator.swift
//  VexSign
//
//  Lists the .appex bundles inside an app so the user can pick injection targets.
//

import Foundation
import NimbleExtensions

enum AppExtensionEnumerator {
	/// Returns the appex bundle names (e.g. "MyWidget.appex") inside an app bundle's
	/// PlugIns and Extensions directories. This is best-effort for the picker;
	/// signing uses `appexBundlesForInjection` to surface read failures.
	static func appexNames(in appBundle: URL) -> [String] {
		appexBundles(in: appBundle).map { $0.lastPathComponent }
	}

	static func appexBundles(in appBundle: URL) -> [URL] {
		let fm = FileManager.default
		var result: [URL] = []

		for sub in ["PlugIns", "Extensions"] {
			let directory = appBundle.appendingPathComponent(sub)
			guard fm.fileExists(atPath: directory.path) else { continue }

			guard let contents = try? fm.contentsOfDirectory(
				at: directory,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			) else { continue }

			result.append(contentsOf: contents.filter {
				$0.pathExtension.lowercased() == "appex" && $0.hasDirectoryPath
			})
		}

		return result
	}

	/// Signing must not mistake a directory read failure or malformed .appex for
	/// an app with no extensions. Keep the best-effort picker above separate.
	static func appexBundlesForInjection(in appBundle: URL, fileManager: FileManager = .default) throws -> [URL] {
		var result: [URL] = []
		// Listing the app first distinguishes a missing folder from a read failure.
		let rootEntries = try fileManager.contentsOfDirectory(at: appBundle, includingPropertiesForKeys: nil)
		for sub in ["PlugIns", "Extensions"] {
			guard let directory = rootEntries.first(where: { $0.lastPathComponent.caseInsensitiveCompare(sub) == .orderedSame }) else { continue }
			let attributes = try fileManager.attributesOfItem(atPath: directory.path)
			guard attributes[.type] as? FileAttributeType == .typeDirectory else {
				throw EnumerationError.invalidDirectory(sub)
			}
			let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
			for entry in entries where entry.pathExtension.lowercased() == "appex" {
				let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
				guard values.isDirectory == true, values.isSymbolicLink != true else {
					throw EnumerationError.invalidExtension(entry.lastPathComponent)
				}
				result.append(entry)
			}
		}
		return result
	}

	enum EnumerationError: LocalizedError, Equatable {
		case invalidDirectory(String)
		case invalidExtension(String)

		var errorDescription: String? {
			switch self {
			case .invalidDirectory(let name):
				return .localized("The app's %@ extension directory is invalid.", arguments: name)
			case .invalidExtension(let name):
				return .localized("The extension %@ is not a safe directory.", arguments: name)
			}
		}
	}

	/// Resolves the on-disk appex names for a library app (imported or signed).
	static func appexNames(for app: AppInfoPresentable) -> [String] {
		guard let appBundle = Storage.shared.getAppDirectory(for: app) else { return [] }
		return appexNames(in: appBundle)
	}
}
