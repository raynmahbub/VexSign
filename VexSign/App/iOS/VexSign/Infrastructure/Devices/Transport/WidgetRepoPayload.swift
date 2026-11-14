//
//  WidgetRepoPayload.swift
//  VexSign
//
//  The snapshot the "Repository Apps" widget renders: the apps of every
//  repository the user has added, plus a pre-fetched icon cache in the same app
//  group. Widgets get very little time and no reliable network, so the app does
//  the fetching and the extension only reads files it can already see.
//
//  Compiled into BOTH targets (see the widget target's membership exceptions in
//  project.pbxproj), so it stays iOS 16-safe and dependency-free.
//

import Foundation
import SwiftUI
import CryptoKit

struct WidgetRepoPayload: Codable, Equatable {

	// MARK: - Model

	struct App: Codable, Equatable, Identifiable {
		/// `ASRepository.App.currentUniqueId` — the id the app's navigation uses.
		var id: String
		var name: String
		var bundleID: String
		var version: String
		/// File name inside the shared icon cache, when the icon was fetched.
		var iconFile: String?
		/// True when a repository has a newer version than the installed app.
		var hasUpdate: Bool
	}

	struct Source: Codable, Equatable, Identifiable {
		var id: String { url }
		var url: String
		var name: String
		var apps: [App]
	}

	var sources: [Source]
	var lastUpdated: Date

	// MARK: Sharing

	static let defaultsKey = "VexSign.widgetRepoPayload"
	static let iconFolderName = "WidgetIcons"

	/// Apps kept per repository; the widget never shows more than six.
	static let appsPerSource = 8
	/// Repositories kept; the picker lists them, so this only bounds the payload.
	static let maxSources = 12

	static var sharedDefaults: UserDefaults? {
		WidgetStatusPayload.sharedDefaults
	}

	static var sharedContainer: URL? {
		FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetStatusPayload.appGroupIdentifier)
	}

	static var iconCacheURL: URL? {
		sharedContainer?.appendingPathComponent(iconFolderName, isDirectory: true)
	}

	@discardableResult
	func store() -> Bool {
		guard let defaults = Self.sharedDefaults else { return false }
		guard let data = try? JSONEncoder().encode(self) else { return false }
		defaults.set(data, forKey: Self.defaultsKey)
		return true
	}

	static func load() -> WidgetRepoPayload? {
		guard
			let defaults = sharedDefaults,
			let data = defaults.data(forKey: defaultsKey)
		else { return nil }
		return try? JSONDecoder().decode(WidgetRepoPayload.self, from: data)
	}

	static func clear() {
		sharedDefaults?.removeObject(forKey: defaultsKey)
	}

	// MARK: Icon cache

	/// Stable file name for a remote icon URL.
	static func iconFileName(for url: URL) -> String {
		let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
		return digest.map { String(format: "%02x", $0) }.joined() + ".png"
	}

	static func cachedIconURL(for url: URL) -> URL? {
		iconCacheURL?.appendingPathComponent(iconFileName(for: url))
	}

	/// Removes cached icons that no payload references any more.
	static func pruneIconCache(referenced: Set<String>) {
		guard let folder = iconCacheURL,
		      let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
		else { return }

		for file in files where !referenced.contains(file) {
			try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
		}
	}

	// MARK: Convenience for the widget

	/// Every app of one repository, or of all of them when `sourceURL` is nil.
	func apps(in sourceURL: String?) -> [App] {
		guard let sourceURL else { return sources.flatMap { $0.apps } }
		return sources.first { $0.url == sourceURL }?.apps ?? []
	}

	var appCount: Int {
		sources.reduce(0) { $0 + $1.apps.count }
	}

	var isStale: Bool {
		Date().timeIntervalSince(lastUpdated) > 60 * 60 * 24
	}

	/// Shown in the gallery and in previews before the app has written anything.
	static var placeholder: WidgetRepoPayload {
		WidgetRepoPayload(
			sources: [
				Source(
					url: "https://example.com/source.json",
					name: "Example Repository",
					apps: [
						App(id: "a", name: "Sample App", bundleID: "com.example.app", version: "1.0", iconFile: nil, hasUpdate: true),
						App(id: "b", name: "Another App", bundleID: "com.example.another", version: "2.3", iconFile: nil, hasUpdate: false),
						App(id: "c", name: "Third App", bundleID: "com.example.third", version: "0.9", iconFile: nil, hasUpdate: false)
					]
				)
			],
			lastUpdated: Date()
		)
	}
}
