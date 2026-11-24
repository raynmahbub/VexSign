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

	/// Failable because the id *is* the library UUID: an entity built from a row
	/// without one carried a fresh random UUID that no action could ever resolve,
	/// so the shortcut showed "no longer in your library" for an app that is right
	/// there.
	init?(app: AppInfoPresentable) {
		guard let uuid = app.uuid, !uuid.isEmpty else { return nil }
		self.uuid = uuid
		self.name = app.name ?? .localized("App")
		self.bundleID = app.identifier ?? ""
		self.version = app.version ?? ""
		self.isSigned = app.isSigned
	}
}

@available(iOS 17.0, *)
struct VexSignAppQuery: EntityQuery {
	/// The apps a Shortcut may see. The Hidden Apps Vault is opened with the device
	/// owner's biometrics *inside* VexSign; a Shortcut has no equivalent prompt, so a
	/// vaulted app is absent from the picker and cannot be resolved by a stale or
	/// hand-edited shortcut — the same rule the Web Manager applies to `/api/library`.
	@MainActor
	static func visibleApps() -> [AppInfoPresentable] {
		let hidden = AppLockManager.shared.hiddenAppUUIDs
		return Storage.shared.getAllApps().filter {
			AutomationVisibility.isVisible(uuid: $0.uuid, hiddenAppUUIDs: hidden)
		}
	}

	/// The live object behind an entity, or nil when it was deleted since the
	/// shortcut was configured. Every action re-resolves instead of trusting the
	/// snapshot the entity carries, so hiding an app also stops a shortcut that was
	/// configured before it was hidden.
	@MainActor
	static func app(for uuid: String) -> AppInfoPresentable? {
		guard AutomationVisibility.isVisible(uuid: uuid, hiddenAppUUIDs: AppLockManager.shared.hiddenAppUUIDs) else { return nil }
		return Storage.shared.getAllApps().first { $0.uuid == uuid }
	}

	@MainActor
	func entities(for identifiers: [String]) async throws -> [VexSignAppEntity] {
		let apps = Self.visibleApps()
		return identifiers.compactMap { uuid in
			apps.first { $0.uuid == uuid }.flatMap(VexSignAppEntity.init(app:))
		}
	}

	@MainActor
	func suggestedEntities() async throws -> [VexSignAppEntity] {
		// Unsigned apps first: they are the ones people sign from a shortcut.
		Self.visibleApps()
			.sorted { lhs, rhs in
				if lhs.isSigned != rhs.isSigned { return !lhs.isSigned }
				return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast)
			}
			.prefix(50)
			.compactMap(VexSignAppEntity.init(app:))
	}

	@MainActor
	func defaultResult() async -> VexSignAppEntity? {
		try? await suggestedEntities().first
	}
}

// A slot shortcut addresses a saved recovery journal, not a mutable library row.
// Keep this out of VexSignAppQuery: a deleted backup must never resolve as a signable app.
@available(iOS 17.0, *)
struct FixtureBackupEntity: AppEntity {
    let id: String
    let title: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Fixture Backup"
    static let defaultQuery = FixtureBackupQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

@available(iOS 17.0, *)
struct FixtureBackupQuery: EntityQuery {
    @MainActor
    func suggestedEntities() async throws -> [FixtureBackupEntity] {
        guard !AppLockManager.shared.isLocked else { return [] }
        return try FixtureSlotStorage.recoveryEntries().filter { AppLockManager.shared.canOpenFixtureBackup($0) }.map {
            FixtureBackupEntity(id: $0.id, title: "\($0.bundle) · \($0.uuid.prefix(8))")
        }
    }
    @MainActor
    func entities(for identifiers: [String]) async throws -> [FixtureBackupEntity] {
        // Resolve only the opaque handles. The foreground action checks the current
        // journal and both locks before showing metadata; even deleted handles can
        // give a useful diagnostic instead of asking the user to pick another app.
        identifiers.map { FixtureBackupEntity(id: $0, title: .localized("Saved fixture backup")) }
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
