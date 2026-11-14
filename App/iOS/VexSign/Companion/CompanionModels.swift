//
//  CompanionModels.swift
//  VexSign
//
//  The wire format every companion (Apple TV, Apple Vision Pro, Apple Watch)
//  speaks. The shapes deliberately match what the iPhone's Web Manager already
//  serves — `GET /api/status`, `GET /api/library` and `GET /api/updates` in
//  WebManagerServer+API.swift — so a companion never needs a bespoke endpoint,
//  and the watch bridge can send the very same snapshot over WatchConnectivity.
//
//  Foundation only: this file is compiled into the iOS app, the tvOS app, the
//  visionOS app and the watchOS app (see the membership exceptions in
//  project.pbxproj), so it must not touch UIKit or CoreData.
//

import Foundation

// MARK: - Status

/// Mirrors `APIStatus` in WebManagerServer+API.swift.
struct CompanionStatus: Codable, Equatable {
	var certValid: Bool
	var certName: String?
	var certExpiry: String?
	var certDaysRemaining: Int?
	var certRevoked: Bool
	var certPPQLess: Bool?
	var installedApps: Int
	var signedApps: Int
	var pendingUpdates: Int
	var storageFree: Int64?

	/// "30d" / "—" for the big countdown label.
	var certLabel: String {
		guard let days = certDaysRemaining else { return "—" }
		return days <= 0 ? "0d" : "\(days)d"
	}

	var certSummary: String {
		if certRevoked { return "Revoked" }
		guard let days = certDaysRemaining else { return "No certificate" }
		if days <= 0 { return "Expired" }
		if days == 1 { return "Expires tomorrow" }
		return "Expires in \(days) days"
	}
}

// MARK: - Library / updates

/// Mirrors `APILibraryEntry`.
struct CompanionLibraryEntry: Codable, Equatable, Identifiable {
	var id: String { bundleID + version }
	var name: String
	var bundleID: String
	var version: String
	var size: Int
	var signed: Bool

	var sizeLabel: String {
		ByteCountFormatter.string(fromByteCount: Int64(max(size, 0)), countStyle: .file)
	}
}

/// Mirrors `APIUpdateEntry`.
struct CompanionUpdateEntry: Codable, Equatable, Identifiable {
	var id: String { bundleID }
	var name: String
	var bundleID: String
	var installedVersion: String?
	var availableVersion: String?
}

// MARK: - Snapshot

/// Everything a companion renders in one value: what the iPhone app publishes,
/// and what the Web Manager serves in three calls.
struct CompanionSnapshot: Codable, Equatable {
	var status: CompanionStatus
	var library: [CompanionLibraryEntry]
	var updates: [CompanionUpdateEntry]
	var generatedAt: Date

	/// Used by previews and by the watch widget before the first real payload.
	static var placeholder: CompanionSnapshot {
		CompanionSnapshot(
			status: CompanionStatus(
				certValid: true,
				certName: "Development",
				certExpiry: nil,
				certDaysRemaining: 42,
				certRevoked: false,
				certPPQLess: false,
				installedApps: 12,
				signedApps: 9,
				pendingUpdates: 3,
				storageFree: 8_400_000_000
			),
			library: [
				CompanionLibraryEntry(name: "Sample App", bundleID: "com.example.app", version: "1.0", size: 24_500_000, signed: true)
			],
			updates: [
				CompanionUpdateEntry(name: "Sample App", bundleID: "com.example.app", installedVersion: "1.0", availableVersion: "1.1")
			],
			generatedAt: Date()
		)
	}

	/// WatchConnectivity carries `[String: Any]`, so the snapshot travels as JSON
	/// bytes under one key rather than a hand-maintained dictionary.
	static let contextKey = "com.vexsign.companion.snapshot"

	var contextRepresentation: [String: Any] {
		guard let data = try? JSONEncoder().encode(self) else { return [:] }
		return [Self.contextKey: data]
	}

	static func snapshot(from context: [String: Any]) -> CompanionSnapshot? {
		guard let data = context[contextKey] as? Data else { return nil }
		return try? JSONDecoder().decode(CompanionSnapshot.self, from: data)
	}
}

// MARK: - Commands

/// What a companion may ask the iPhone to do. Handled in `CompanionBridge`,
/// which routes each one to the same manager the matching App Intent uses.
enum CompanionCommand: String, Codable, CaseIterable {
	case refreshSources
	case checkCertificates
	case updateAll
	case cleanNow

	var title: String {
		switch self {
		case .refreshSources: return "Refresh repositories"
		case .checkCertificates: return "Check certificates"
		case .updateAll: return "Update all apps"
		case .cleanNow: return "Clean now"
		}
	}

	static let contextKey = "com.vexsign.companion.command"
}
