//
//  VexSignAPI.swift
//  VexSign
//
//  VexSign configuration and constants
//

import Foundation
import UIKit
import Security
#if canImport(AltSourceKit)
import AltSourceKit
#endif

enum VexSignAPI {
	// MARK: - Contact

	static let telegramUsername = "@iamSMMH"
	static let telegramURL = URL(string: "https://t.me/iamSMMH")!
	static let contactSuffix = "Contact \(telegramUsername) on Telegram"

	// MARK: - API

	static let apiBaseURL = "https://vexsign-premium.onrender.com/api"
	/// Key validation (POST, consumes key).
	static let apiValidateEndpoint = "\(apiBaseURL)/validate"
	/// URL preview (GET, doesn't consume key).
	static let apiURLsEndpoint = "\(apiBaseURL)/urls"
	static let apiHealthEndpoint = "\(apiBaseURL)/health"

	// MARK: - API Models

	struct URLsResponse: Decodable {
		struct Item: Decodable {
			let url: String
		}

		let urls: [Item]?
	}

	struct ErrorResponse: Decodable {
		let detail: String

		// Current hosts send a lowercase key; a capitalised variant is also
		// accepted so a differently-cased host never degrades to fallback text.
		enum CodingKeys: String, CodingKey {
			case detail
			case capitalDetail = "Detail"
		}

		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			if let value = try container.decodeIfPresent(String.self, forKey: .capitalDetail) {
				detail = value
			} else {
				detail = try container.decode(String.self, forKey: .detail)
			}
		}
	}

	// MARK: - Repos

	static let reposListURL = URL(string: "https://raw.githubusercontent.com/raynmahbub/VexSign/refs/heads/main/repos.json")!

	// MARK: - Device Identity

	static var deviceUUID: String? {
		if let existing = IdentityVault.read(.deviceUUID) {
			return existing
		}

		let uuid = UUID().uuidString
		IdentityVault.write(.deviceUUID, uuid)
		return uuid
	}

	// MARK: - Premium API Key

	/// Developer override: hardcode your own key here and it is picked up on first
	/// launch (e.g. `static let developerPremiumAPIKey = "VEX-XXXX-XXXX-XXXX"`).
	/// Leave empty to rely on the in-app "Redeem Key" flow, which persists the key
	/// so it survives relaunches.
	static let developerPremiumAPIKey = ""

	// MARK: - Self-managed / local premium mode
	//
	// If you don't own a key from https://github.com/raynmahbub/VexSign, you can run your own
	// "premium" setup without that server. Set `localModePremiumKey` to any
	// VEX-…-formatted key you invent, and `localModePremiumURLs` to the repository
	// feeds that key should unlock. Then redeeming that exact key in the app skips
	// the remote /validate call entirely and activates your local repo list.

	/// The key accepted in local mode (empty disables local mode). Must keep the
	/// client-side "VEX-" format check happy (prefix + at least 16 chars).
	static let localModePremiumKey = "" // e.g. "VEX-LOCAL-DEV-KEY-0001"

	/// Repository URLs that a matching local key unlocks — e.g. your own altstore
	/// JSON feeds: ["https://your-host.com/premium.json", …].
	static let localModePremiumURLs: [String] = []

	/// The persisted premium API key. Backed by the keychain (via IdentityVault), so
	/// a redeemed key keeps working across launches instead of living only in memory.
	static var premiumAPIKey: String? {
		get { IdentityVault.read(.premiumAPIKey) }
		set {
			if let newValue, !newValue.isEmpty {
				IdentityVault.write(.premiumAPIKey, newValue)
			} else {
				IdentityVault.delete(.premiumAPIKey)
			}
		}
	}

	// MARK: - Premium State

	static var isPremium: Bool {
		get { IdentityVault.read(.premiumActive) == "true" }
		set {
			if newValue {
				IdentityVault.write(.premiumActive, "true")
			} else {
				IdentityVault.delete(.premiumActive)
			}
		}
	}

	static func savePremiumURLs(_ urls: [URL]) {
		let strings = urls.map { $0.absoluteString }
		guard
			let data = try? JSONEncoder().encode(strings),
			let encoded = String(data: data, encoding: .utf8)
		else {
			return
		}

		IdentityVault.write(.premiumURLs, encoded)
	}

	static func getSavedPremiumURLs() -> [URL]? {
		guard
			let encoded = IdentityVault.read(.premiumURLs),
			let data = encoded.data(using: .utf8),
			let strings = try? JSONDecoder().decode([String].self, from: data)
		else {
			return nil
		}

		let urls = strings.compactMap { URL(string: $0) }
		return urls.isEmpty ? nil : urls
	}

	static func clearPremiumIdentity() {
		IdentityVault.delete(.premiumActive)
		IdentityVault.delete(.premiumURLs)
		IdentityVault.delete(.premiumAPIKey)
	}

	/// Activation survived in the vault but this install has no premium sources.
	static var hasStoredPremiumButNotLocal: Bool {
		isPremium && premiumSourceHosts.isEmpty
	}

	// MARK: - Migration

	/// Rebuilds the vault from this install, so a wiped keychain doesn't cost premium access.
	static func migrateIfNeeded() {
		let hosts = premiumSourceHosts
		guard !hosts.isEmpty else { return }

		if !isPremium {
			isPremium = true
		}

		guard getSavedPremiumURLs() == nil else { return }

		let premiumURLs = Storage.shared.getSources().compactMap { $0.sourceURL }.filter { url in
			guard let host = url.host?.lowercased() else { return false }
			return hosts.contains(host)
		}

		if !premiumURLs.isEmpty {
			savePremiumURLs(premiumURLs)
		}
	}

	// MARK: - Premium Sources Storage (UserDefaults)

	private static let premiumSourcesKey = "VexSign.premiumSourceHosts"

	static var premiumSourceHosts: Set<String> {
		get {
			let array = UserDefaults.standard.stringArray(forKey: premiumSourcesKey) ?? []
			return Set(array)
		}
		set {
			UserDefaults.standard.set(Array(newValue), forKey: premiumSourcesKey)
		}
	}

	static func registerPremiumSource(_ url: URL) {
		guard let host = url.host?.lowercased() else { return }
		var hosts = premiumSourceHosts
		hosts.insert(host)
		premiumSourceHosts = hosts
	}

	static func registerPremiumSources(_ urls: [URL]) {
		var hosts = premiumSourceHosts
		for url in urls {
			if let host = url.host?.lowercased() {
				hosts.insert(host)
			}
		}
		premiumSourceHosts = hosts
	}

	static func isPremiumSource(_ url: URL) -> Bool {
		guard let host = url.host?.lowercased() else { return false }
		return premiumSourceHosts.contains(host)
	}

	/// Unregister a premium source host once no remaining source uses it.
	static func unregisterPremiumSourceIfNeeded(_ url: URL, remainingSourceURLs: [URL]) {
		guard let host = url.host?.lowercased() else { return }
		guard premiumSourceHosts.contains(host) else { return }

		let otherSourcesWithSameHost = remainingSourceURLs.filter { sourceURL in
			guard let sourceHost = sourceURL.host?.lowercased() else { return false }
			return sourceHost == host
		}

		if otherSourcesWithSameHost.isEmpty {
			var hosts = premiumSourceHosts
			hosts.remove(host)
			premiumSourceHosts = hosts
		}
	}

	static func authHeaders(for url: URL) -> [String: String] {
		guard isPremiumSource(url), let uuid = deviceUUID else {
			return [:]
		}
		return ["vexSignUUID": uuid]
	}

	/// Lets the server trim the payload instead of downloading the whole catalog first.
	@MainActor
	static func catalogURL(for url: URL) -> URL {
		guard isPremiumSource(url) else { return url }

		let items = PremiumFilterPreferences.shared.queryItems
		guard
			!items.isEmpty,
			var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		else {
			return url
		}

		components.queryItems = (components.queryItems ?? []) + items
		return components.url ?? url
	}

	static func applyAuthHeaders(to request: inout URLRequest) {
		guard let url = request.url, isPremiumSource(url), let uuid = deviceUUID else {
			return
		}
		request.setValue(uuid, forHTTPHeaderField: "vexSignUUID")
		#if canImport(AltSourceKit)
		// Add the premium repository API key to IPA/manifest downloads from
		// premium hosts (single source of truth: EsignSourceKey.customApiKey).
		if !EsignSourceKey.customApiKey.isEmpty, request.value(forHTTPHeaderField: "X-API-Key") == nil {
			request.setValue(EsignSourceKey.customApiKey, forHTTPHeaderField: "X-API-Key")
		}
		#endif
	}

	// MARK: - Excluded Sources

	private static let excludedSourcesKey = "VexSign.excludedSourceIdentifiers"

	/// Set of source identifiers excluded from "All Repositories"
	static var excludedSourceIdentifiers: Set<String> {
		get {
			let array = UserDefaults.standard.stringArray(forKey: excludedSourcesKey) ?? []
			return Set(array)
		}
		set {
			UserDefaults.standard.set(Array(newValue), forKey: excludedSourcesKey)
		}
	}

	static func isSourceExcluded(_ identifier: String) -> Bool {
		excludedSourceIdentifiers.contains(identifier)
	}

	static func setSourceExcluded(_ identifier: String, excluded: Bool) {
		var ids = excludedSourceIdentifiers
		if excluded {
			ids.insert(identifier)
		} else {
			ids.remove(identifier)
		}
		excludedSourceIdentifiers = ids
	}

	// MARK: - Helper Methods

	static func openTelegram() {
		UIApplication.shared.open(telegramURL)
	}

	static func errorMessage(_ message: String, includeContact: Bool = false) -> String {
		if includeContact {
			return "\(message)\n\n\(contactSuffix)"
		}
		return message
	}
}
