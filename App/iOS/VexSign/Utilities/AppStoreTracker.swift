//
//  AppStoreTracker.swift
//  VexSign
//
//  Asks the public iTunes Search API what the latest App Store version of a
//  bundle ID is, so the library can badge apps that have a newer public release
//  than the sideloaded copy. Lookup is by bundle ID (the API supports it
//  directly), so no name guessing and no scraping.
//
//  Read-only: nothing here installs or downloads anything.
//

import Foundation
import OSLog
import NimbleExtensions

// MARK: - Model

struct AppStoreInfo: Codable, Sendable, Equatable {
	let name: String
	let bundleID: String
	let version: String
	let releaseDate: Date?
	let storeURL: String?
}

// MARK: - Tracker

enum AppStoreTracker {
	enum TrackerError: LocalizedError {
		case invalidBundleID
		case invalidURL
		case decoding(String)
		case transport(String)

		var errorDescription: String? {
			switch self {
			case .invalidBundleID: String.localized("That bundle identifier is empty.")
			case .invalidURL: String.localized("Could not build the App Store lookup URL.")
			case .decoding(let detail): String.localized("Unexpected App Store response: %@", arguments: detail)
			case .transport(let detail): String.localized("App Store lookup failed: %@", arguments: detail)
			}
		}
	}

	/// iTunes Search API — free, unauthenticated, returns JSON.
	static let lookupEndpoint = "https://itunes.apple.com/lookup"

	/// Builds the lookup request. `country` only affects which storefront answers.
	static func requestURL(for bundleID: String, country: String = "us") -> URL? {
		let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }

		var components = URLComponents(string: lookupEndpoint)
		components?.queryItems = [
			URLQueryItem(name: "bundleId", value: trimmed),
			URLQueryItem(name: "country", value: country),
			URLQueryItem(name: "entity", value: "software"),
		]
		return components?.url
	}

	/// Latest App Store entry for a bundle ID, or nil when the app isn't listed
	/// (sideload-only apps, removed apps, regional gaps).
	static func latest(for bundleID: String, session: URLSession = .shared) async throws -> AppStoreInfo? {
		guard let url = requestURL(for: bundleID) else { throw TrackerError.invalidBundleID }

		let data: Data
		do {
			let (fetched, _) = try await session.data(from: url)
			data = fetched
		} catch {
			throw TrackerError.transport(error.localizedDescription)
		}

		return try decode(data)
	}

	/// Decoding is split out so it can be tested against canned payloads.
	static func decode(_ data: Data) throws -> AppStoreInfo? {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601

		let response: LookupResponse
		do {
			response = try decoder.decode(LookupResponse.self, from: data)
		} catch {
			throw TrackerError.decoding(error.localizedDescription)
		}

		// The API echoes the exact bundle ID back; only trust a match.
		guard let match = response.results?.first(where: { !$0.version.isEmpty }) ?? response.results?.first else {
			return nil
		}
		return AppStoreInfo(
			name: match.trackName,
			bundleID: match.bundleId,
			version: match.version,
			releaseDate: match.currentVersionReleaseDate,
			storeURL: match.trackViewUrl
		)
	}

	/// Same version rules the source-based update checker uses.
	static func hasUpdate(installedVersion: String?, latestVersion: String?) -> Bool {
		AppUpdateChecker.shared.hasUpdate(installedVersion: installedVersion, sourceVersion: latestVersion)
	}

	// MARK: Response shape

	struct LookupResponse: Codable, Sendable {
		let resultCount: Int?
		let results: [LookupResult]?
	}

	struct LookupResult: Codable, Sendable {
		let trackName: String
		let bundleId: String
		let version: String
		let trackViewUrl: String?
		let currentVersionReleaseDate: Date?

		enum CodingKeys: String, CodingKey {
			case trackName
			case bundleId
			case version
			case trackViewUrl
			case currentVersionReleaseDate
		}

		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			trackName = try container.decodeIfPresent(String.self, forKey: .trackName) ?? ""
			bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId) ?? ""
			version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
			trackViewUrl = try container.decodeIfPresent(String.self, forKey: .trackViewUrl)
			currentVersionReleaseDate = try container.decodeIfPresent(Date.self, forKey: .currentVersionReleaseDate)
		}
	}
}

// MARK: - Library badge store

/// Caches App Store lookups for the library so scrolling never hits the network.
/// Opt-in through Settings → Updates → "App Store update tracking".
@MainActor
final class AppStoreUpdateTracker: ObservableObject {
	static let shared = AppStoreUpdateTracker()

	static let enabledKey = "VexSign.appStoreUpdateTracking"

	@Published private(set) var infos: [String: AppStoreInfo] = [:]
	@Published private(set) var isRefreshing = false

	private var _checkedIDs: Set<String> = []

	private init() {}

	static var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: enabledKey)
	}

	/// Latest known App Store version for a bundle ID, if it was already looked up.
	func info(for bundleID: String?) -> AppStoreInfo? {
		guard let bundleID, !bundleID.isEmpty else { return nil }
		return infos[bundleID]
	}

	/// Newer public version available for this app?
	func hasNewerVersion(than app: AppInfoPresentable) -> Bool {
		guard let info = info(for: app.identifier) else { return false }
		return AppStoreTracker.hasUpdate(installedVersion: app.version, latestVersion: info.version)
	}

	/// Looks up every app that hasn't been checked yet this session.
	func refresh(apps: [AppInfoPresentable]) async {
		guard Self.isEnabled, !isRefreshing else { return }

		let pending = apps
			.compactMap { $0.identifier }
			.filter { !$0.isEmpty && !_checkedIDs.contains($0) }

		guard !pending.isEmpty else { return }

		isRefreshing = true
		defer { isRefreshing = false }

		let found: [(String, AppStoreInfo?)] = await withTaskGroup(of: (String, AppStoreInfo?).self) { group in
			for bundleID in pending {
				group.addTask {
					let info = try? await AppStoreTracker.latest(for: bundleID)
					return (bundleID, info)
				}
			}

			var collected: [(String, AppStoreInfo?)] = []
			for await result in group {
				collected.append(result)
			}
			return collected
		}

		var updated = infos
		for (bundleID, info) in found {
			_checkedIDs.insert(bundleID)
			if let info { updated[bundleID] = info }
		}
		infos = updated
	}

	func clearCache() {
		infos = [:]
		_checkedIDs = []
	}
}
