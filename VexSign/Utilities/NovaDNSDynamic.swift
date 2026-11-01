//
//  NovaDNSDynamic.swift
//  VexSign
//
//  Created by NovaDev404 on 24.02.2026.
//  Imported from NexStore for VexSign with dynamic rule fetching.
//
//  the endpoint is configurable and shown in Settings, the feature stays off by default,
//  and every time it is used VexSign says so in the log. What it does not do — and cannot do — is
//  promise anything about revocation: it asks a third-party server to change how this device
//  resolves Apple's install-time checks. The server's behaviour, and Apple's, are outside the app.
//

import Foundation

public struct DynamicDNSRules: Codable, Sendable {
	public let version: Int
	public let lastUpdated: String?
	public let primaryEndpoint: String
	public let fallbackEndpoints: [String]?
	public let blockedHosts: [String]

	public static let `default` = DynamicDNSRules(
		version: 1,
		lastUpdated: "2026-09-19",
		primaryEndpoint: "https://dns.novadev.vip/dns-query",
		fallbackEndpoints: ["https://dns.adguard-dns.com/dns-query"],
		blockedHosts: [
			"ocsp.apple.com",
			"ocsp2.apple.com",
			"valid.apple.com",
			"certs.apple.com",
			"crl.apple.com",
			"crl.apple.com.akadns.net",
			"ocsp.apple.com.akadns.net"
		]
	)
}

public enum NovaDNSDynamic: Sendable {
	// MARK: Endpoints

	/// The rule list VexSign used to fetch from unconditionally. It stays the default, but it is a
	/// default now, not an assumption: see `customRulesURL`.
	public static let defaultRulesURL = "https://api.novadev.vip/api/novadns-dynamic/rules.json"

	/// Where a user's override lives. Empty/unset means "use `defaultRulesURL`".
	public static let customRulesURLKey = "VexSign.novaDNSRulesURL"

	/// The override, but only while it is still a usable `https://` URL. A stored value that no
	/// longer parses (a typo saved by an older build) falls back to the default rather than
	/// silently doing nothing.
	public static var customRulesURL: String? {
		guard
			let stored = UserDefaults.standard.string(forKey: customRulesURLKey)?
				.trimmingCharacters(in: .whitespacesAndNewlines),
			!stored.isEmpty,
			isUsable(stored)
		else {
			return nil
		}
		return stored
	}

	/// What the app will actually contact, as a string. Shown in Settings.
	public static var effectiveRulesURLString: String {
		customRulesURL ?? defaultRulesURL
	}

	public static var rulesURL: URL? {
		URL(string: effectiveRulesURLString)
	}

	/// The API base is the rule list's folder, so an override of the rules endpoint moves every
	/// action with it.
	public static func actionURL(_ action: String) -> URL? {
		guard let rules = rulesURL else { return nil }
		return rules.deletingLastPathComponent().appendingPathComponent(action)
	}

	/// Stores an override. Returns false (and changes nothing) when the string is not an absolute
	/// `https://` URL; an empty or nil string clears the override and restores the default.
	@discardableResult
	public static func setCustomRulesURL(_ raw: String?) -> Bool {
		let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

		guard !trimmed.isEmpty else {
			UserDefaults.standard.removeObject(forKey: customRulesURLKey)
			FileLogger.log("NovaDNS: rules endpoint reset to the default", category: "antirevoke")
			return true
		}

		guard isUsable(trimmed) else {
			FileLogger.warn("NovaDNS: rejected rules endpoint (not an https URL): \(trimmed)", category: "antirevoke")
			return false
		}

		UserDefaults.standard.set(trimmed, forKey: customRulesURLKey)
		FileLogger.log("NovaDNS: rules endpoint set to \(trimmed)", category: "antirevoke")
		return true
	}

	private static func isUsable(_ string: String) -> Bool {
		guard let url = URL(string: string) else { return false }
		return url.scheme?.lowercased() == "https" && (url.host?.isEmpty == false)
	}

	// MARK: Actions

	/// Sends a one-shot command (currently `enablePPQ`) to the configured service.
	///
	/// Failures are logged rather than swallowed: an anti-revoke feature that quietly stops working
	/// is worse than one that says it could not reach its endpoint.
	public static func sendRequest(endpoint: String) async {
		guard let url = actionURL(endpoint) else {
			FileLogger.error("NovaDNS: no usable endpoint for \(endpoint)", category: "antirevoke")
			return
		}

		var request = URLRequest(url: url)
		request.httpMethod = "POST"

		do {
			let (_, response) = try await URLSession.shared.data(for: request)
			let status = (response as? HTTPURLResponse)?.statusCode ?? -1
			if !(200..<300).contains(status) {
				FileLogger.warn("NovaDNS: \(endpoint) answered \(status) from \(url.host ?? "?")", category: "antirevoke")
			}
		} catch {
			FileLogger.error("NovaDNS: \(endpoint) failed — \(error.localizedDescription)", category: "antirevoke")
		}
	}

	// MARK: Rules

	private static let cachedRulesKey = "VexSign.dynamicDNSRulesCache"

	/// Fetches the dynamic rules from a remote JSON endpoint. Falls back to cached or default rules.
	public static func fetchRules(from customURL: String? = nil) async -> DynamicDNSRules {
		let requested = customURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let endpointString = requested.isEmpty ? effectiveRulesURLString : requested

		guard let url = URL(string: endpointString), url.scheme?.lowercased() == "https" else {
			FileLogger.warn("NovaDNS: rules endpoint is not an https URL: \(endpointString)", category: "antirevoke")
			return loadCachedRules()
		}

		do {
			var request = URLRequest(url: url)
			request.timeoutInterval = 10.0
			let (data, response) = try await URLSession.shared.data(for: request)
			guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
				let status = (response as? HTTPURLResponse)?.statusCode ?? -1
				FileLogger.warn("NovaDNS: rules request answered \(status) from \(url.host ?? "?")", category: "antirevoke")
				return loadCachedRules()
			}

			let rules = try JSONDecoder().decode(DynamicDNSRules.self, from: data)
			saveCachedRules(rules)
			FileLogger.log("NovaDNS: rules updated from \(url.host ?? "?"), blocking \(rules.blockedHosts.count) hosts", category: "antirevoke")
			return rules
		} catch {
			FileLogger.warn("NovaDNS: rules fetch from \(url.host ?? "?") failed — \(error.localizedDescription)", category: "antirevoke")
			return loadCachedRules()
		}
	}

	public static func loadCachedRules() -> DynamicDNSRules {
		if let data = UserDefaults.standard.data(forKey: cachedRulesKey),
		   let rules = try? JSONDecoder().decode(DynamicDNSRules.self, from: data) { // try? ok: a corrupt cache is the same as no cache — the default rules follow
			return rules
		}
		return .default
	}

	public static func saveCachedRules(_ rules: DynamicDNSRules) {
		do {
			let data = try JSONEncoder().encode(rules)
			UserDefaults.standard.set(data, forKey: cachedRulesKey)
		} catch {
			FileLogger.error("NovaDNS: could not cache rules — \(error.localizedDescription)", category: "antirevoke")
		}
	}
}
