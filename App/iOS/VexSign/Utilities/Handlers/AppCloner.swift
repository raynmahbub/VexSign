//
//  AppCloner.swift
//  VexSign
//
//  Clones/duplicates an existing app bundle with a modified bundle ID and display name,
//  storing the duplicate as a new independent library entry.
//

import Foundation
import UIKit
import NimbleExtensions

@MainActor
final class AppCloner {
	static let shared = AppCloner()

	private let _fm = FileManager.default

	enum CloneError: LocalizedError {
		case appNotFound
		case copyFailed
		case plistFailed

		var errorDescription: String? {
			switch self {
			case .appNotFound: String.localized("App files not found.")
			case .copyFailed: String.localized("Failed to duplicate app files.")
			case .plistFailed: String.localized("Failed to update Info.plist.")
			}
		}
	}

	func clone(app: AppInfoPresentable, customName: String? = nil, customBundleId: String? = nil, asUnsigned: Bool = false, iconOrdinal: Int? = nil) async throws -> AppInfoPresentable {
        let lease = try AppOperationRegistry.shared.acquire(AppOperationRegistry.key(app))
        defer { withExtendedLifetime(lease) {} }
		guard let srcDir = Storage.shared.getUuidDirectory(for: app), _fm.fileExists(atPath: srcDir.path) else {
			throw CloneError.appNotFound
		}

        var registered = false
        let newUUID = UUID().uuidString
		let destDir = (app.isSigned && !asUnsigned) ? _fm.signed(newUUID) : _fm.unsigned(newUUID)

        defer { if !registered { try? _fm.removeItem(at: destDir) } }
        do {
            try await Task.detached(priority: .userInitiated) { try StoragePreflight.checkBundle(srcDir, copies: 1, destination: destDir.deletingLastPathComponent()); try FileManager.default.copyItem(at: srcDir, to: destDir) }.value
        } catch let error as StoragePreflight.Insufficient {
            throw error
        } catch is CancellationError {
            throw CancellationError()
		} catch {
			try? _fm.removeItem(at: destDir)
			throw CloneError.copyFailed
		}

		guard let appBundle = _fm.getPath(in: destDir, for: "app") else {
			try? _fm.removeItem(at: destDir)
			throw CloneError.appNotFound
		}

        guard appBundle.resolvingSymlinksInPath().path.hasPrefix(destDir.resolvingSymlinksInPath().path + "/") else { throw CloneError.appNotFound }
        let newName = customName ?? "\(app.name ?? .localized("App")) Copy"
		let newBundleId = customBundleId ?? "\(app.identifier ?? "app").copy"

		// Update Info.plist
		let infoPlistURL = appBundle.appendingPathComponent("Info.plist")
        guard infoPlistURL.resolvingSymlinksInPath().path.hasPrefix(appBundle.resolvingSymlinksInPath().path + "/") else { throw CloneError.plistFailed }
        if var plist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] {
			plist["CFBundleName"] = newName
			plist["CFBundleDisplayName"] = newName
			plist["CFBundleIdentifier"] = newBundleId
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
                try data.write(to: infoPlistURL, options: .atomic)
            } catch {
                try? _fm.removeItem(at: destDir)
                throw CloneError.plistFailed
            }
        } else {
            try? _fm.removeItem(at: destDir)
            throw CloneError.plistFailed
        }

        if asUnsigned, let oldID = app.identifier {
            try await Task.detached(priority: .userInitiated) {
                guard let files = FileManager.default.enumerator(at: appBundle, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { throw CloneError.appNotFound }
                // `nextObject()` rather than `for … in files`: NSEnumerator's
                // `makeIterator()` is unavailable from asynchronous contexts.
                while let file = files.nextObject() as? URL {
                    guard file.lastPathComponent == "Info.plist", file != infoPlistURL else { continue }
                    guard file.resolvingSymlinksInPath().path.hasPrefix(appBundle.resolvingSymlinksInPath().path + "/") else { throw CloneError.plistFailed }
                    var format = PropertyListSerialization.PropertyListFormat.binary
                    guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), options: [], format: &format) as? [String: Any] else { continue }
                    var changed = false
                    for key in ["CFBundleIdentifier", "WKCompanionAppBundleIdentifier", "WKAppBundleIdentifier"] {
                        if let value = plist[key] as? String, value == oldID || value.hasPrefix(oldID + ".") {
                            plist[key] = newBundleId + value.dropFirst(oldID.count)
                            changed = true
                        }
                    }
                    if changed { try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: file, options: .atomic) }
                }
            }.value
        }

        if let iconOrdinal, let icon = app.icon {
            let candidates = [appBundle.appendingPathComponent(icon), appBundle.appendingPathComponent(icon + ".png")]
            if let iconURL = candidates.first(where: { _fm.fileExists(atPath: $0.path) && $0.resolvingSymlinksInPath().path.hasPrefix(appBundle.resolvingSymlinksInPath().path + "/") }),
               let image = UIImage(contentsOfFile: iconURL.path), image.size.width > 0, image.size.height > 0, image.size.width <= 1024, image.size.height <= 1024 {
                let renderer = UIGraphicsImageRenderer(size: image.size)
                let result = renderer.image { context in
                    image.draw(at: .zero)
                    let diameter = min(image.size.width, image.size.height) * 0.42
                    let rect = CGRect(x: image.size.width - diameter, y: image.size.height - diameter, width: diameter, height: diameter)
                    UIColor.systemBlue.setFill()
                    context.cgContext.fillEllipse(in: rect)
                    let text = "\(iconOrdinal)" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: diameter * 0.55), .foregroundColor: UIColor.white]
                    let size = text.size(withAttributes: attrs)
                    text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
                }
                if let png = result.pngData() { try png.write(to: iconURL, options: .atomic) }
            }
        }

        // Register in database. The write runs off the main actor and returns
        // an object ID; the row is resolved here, on the main actor.
        if app.isSigned && !asUnsigned {
            try await Storage.shared.addSigned(
                uuid: newUUID,
                appName: newName,
                appIdentifier: newBundleId,
                originalAppIdentifier: app.originalIdentifier ?? app.identifier,
                appVersion: app.version,
                appIcon: app.icon,
                appDescription: app.appDescription
            )
        } else {
            try await Storage.shared.addImported(
                uuid: newUUID,
                appName: newName,
                appIdentifier: newBundleId,
                appVersion: app.version,
                appIcon: app.icon,
                appDescription: app.appDescription
            )
        }

        registered = true

        guard let result: AppInfoPresentable = Storage.shared.app(withUuid: newUUID) else {
            throw CloneError.copyFailed
        }

        return result
    }
}
