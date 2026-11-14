//
//  VexSignEntities.swift
//  VexSign
//
//  The nouns Shortcuts can talk about: a library app, a repository and the
//  places inside the app a shortcut can open. Entities are resolved from the
//  same `Storage` the UI reads, so a shortcut can never act on an app the
//  library does not have.
//

import Foundation
import AppIntents
import SwiftUI
import NimbleExtensions

// MARK: - Library app

/// One app in the library, addressed by its Core Data UUID.
@available(iOS 17.0, *)
struct VexSignAppEntity: AppEntity {
	let uuid: String
	let name: String
	let bundleID: String
	let version: String
	let isSigned: Bool

	static let typeDisplayRepresentation: TypeDisplayRepresentation = "VexSign App"
	static let defaultQuery = VexSignAppQuery()

	var id: String { uuid }

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(
			title: "\(name)",
			subtitle: "\(isSigned ? .localized("Signed") : .localized("Unsigned")) · \(version)"
		)
	}

	init(app: AppInfoPresentable) {
		self.uuid = app.uuid ?? UUID().uuidString
		self.name = app.name ?? .localized("App")
		self.bundleID = app.identifier ?? ""
		self.version = app.version ?? ""
		self.isSigned = app.isSigned
	}
}

@available(iOS 17.0, *)
struct VexSignAppQuery: EntityQuery {
	/// The live object behind an entity, or nil when it was deleted since the
	/// shortcut was configured. Every action re-resolves instead of trusting the
	/// snapshot the entity carries.
	@MainActor
	static func app(for uuid: String) -> AppInfoPresentable? {
		Storage.shared.getAllApps().first { $0.uuid == uuid }
	}

	@MainActor
	func entities(for identifiers: [String]) async throws -> [VexSignAppEntity] {
		let apps = Storage.shared.getAllApps()
		return identifiers.compactMap { uuid in
			apps.first { $0.uuid == uuid }.map(VexSignAppEntity.init(app:))
		}
	}

	@MainActor
	func suggestedEntities() async throws -> [VexSignAppEntity] {
		// Unsigned apps first: they are the ones people sign from a shortcut.
		Storage.shared.getAllApps()
			.sorted { lhs, rhs in
				if lhs.isSigned != rhs.isSigned { return !lhs.isSigned }
				return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast)
			}
			.prefix(50)
			.map(VexSignAppEntity.init(app:))
	}

	@MainActor
	func defaultResult() async -> VexSignAppEntity? {
		try? await suggestedEntities().first
	}
}

// MARK: - Repository

/// A repository the user has added, addressed by its feed URL.
@available(iOS 17.0, *)
struct VexSignSourceEntity: AppEntity {
	let url: String
	let name: String
	let identifier: String

	static let typeDisplayRepresentation: TypeDisplayRepresentation = "Repository"
	static let defaultQuery = VexSignSourceQuery()

	var id: String { url }

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)", subtitle: "\(url)")
	}
}

@available(iOS 17.0, *)
struct VexSignSourceQuery: EntityQuery {
	@MainActor
	static func sources() -> [AltSource] {
		Storage.shared.getSources()
	}

	@MainActor
	static func source(for url: String) -> AltSource? {
		sources().first { $0.sourceURL?.absoluteString == url }
	}

	@MainActor
	func entities(for identifiers: [String]) async throws -> [VexSignSourceEntity] {
		let all = Self.sources()
		return identifiers.compactMap { url in
			guard let source = all.first(where: { $0.sourceURL?.absoluteString == url }) else { return nil }
			return VexSignSourceEntity(
				url: url,
				name: source.name ?? url,
				identifier: source.identifier ?? url
			)
		}
	}

	@MainActor
	func suggestedEntities() async throws -> [VexSignSourceEntity] {
		Self.sources().compactMap { source in
			guard let url = source.sourceURL?.absoluteString else { return nil }
			return VexSignSourceEntity(
				url: url,
				name: source.name ?? url,
				identifier: source.identifier ?? url
			)
		}
	}

	@MainActor
	func defaultResult() async -> VexSignSourceEntity? {
		try? await suggestedEntities().first
	}
}

// MARK: - Destination

/// Where "Open VexSign" can take you. Tab-level destinations only, so a shortcut
/// never depends on a navigation stack that may not exist.
@available(iOS 17.0, *)
enum VexSignSection: String, AppEnum {
	case home
	case library
	case appStore
	case files
	case downloads
	case settings
	case ipaExplorer

	static var typeDisplayRepresentation: TypeDisplayRepresentation = "VexSign Section"

	static var caseDisplayRepresentations: [VexSignSection: DisplayRepresentation] = [
		.home: "Home",
		.library: "Library",
		.appStore: "Discover",
		.files: "Files",
		.downloads: "Tasks",
		.settings: "Settings",
		.ipaExplorer: "IPA Explorer"
	]

	var tab: TabEnum? {
		switch self {
		case .home: return .home
		case .library: return .library
		case .appStore: return .appStore
		case .files: return .files
		case .downloads: return .downloads
		case .settings: return .settings
		case .ipaExplorer: return nil
		}
	}
}
