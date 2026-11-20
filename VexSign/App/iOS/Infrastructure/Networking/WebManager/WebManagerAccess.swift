//
//  WebManagerAccess.swift
//  VexSign
//
//  Who can reach the Web Manager, on which interface, and what they may do once
//  they are there. Deliberately free of Vapor and UIKit so the rules can be unit
//  tested without starting a server.
//

import Foundation
import Security
import NimbleExtensions

// MARK: - Bind mode

/// Where the Web Manager listens.
enum WebManagerBindMode: String, CaseIterable, Identifiable {
	/// Loopback only: the device itself (Safari, the Files app, an on-device shortcut).
	/// Nothing else on the network can open a connection, not even a port scan.
	case thisDevice
	/// Every interface, so a computer or a companion device on the same network can connect.
	case localNetwork

	var id: String { rawValue }

	var title: String {
		switch self {
		case .thisDevice: String.localized("This device only")
		case .localNetwork: String.localized("This network")
		}
	}

	var detail: String {
		switch self {
		case .thisDevice:
			String.localized("Listens on 127.0.0.1. Only apps on this device can connect.")
		case .localNetwork:
			String.localized("Listens on every interface so other devices on this network can connect.")
		}
	}

	/// The address passed to the HTTP server for this mode.
	var hostname: String {
		switch self {
		case .thisDevice: "127.0.0.1"
		case .localNetwork: "0.0.0.0"
		}
	}
}

// MARK: - Policy

/// The access rules the server and the settings UI share.
enum WebManagerAccessPolicy {
	/// Header a client sends instead of, or in addition to, Basic credentials.
	static let tokenHeader = "X-VexSign-Token"

	/// Normalises a request path: percent-decoded, lowercased, no trailing slash,
	/// collapsed slashes. Two spellings of the same path must classify the same.
	static func normalizedPath(_ path: String) -> String {
		let decoded = (path.removingPercentEncoding ?? path).lowercased()
		var result = ""
		var lastWasSlash = false
		for character in decoded {
			if character == "/" {
				if lastWasSlash { continue }
				lastWasSlash = true
			} else {
				lastWasSlash = false
			}
			result.append(character)
		}
		while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
		return result.isEmpty ? "/" : result
	}

	/// Endpoints that hand out signing identity or destroy library content.
	///
	/// These are gated even when the server as a whole runs without a password:
	/// a certificate bundle contains the private key, and a DELETE is not something
	/// an unauthenticated peer should be able to send.
	static func requiresSensitiveAccess(path: String, isDestructive: Bool) -> Bool {
		let normalized = normalizedPath(path)

		if normalized == "/api/certs" || normalized.hasPrefix("/api/certs/") { return true }
		if normalized == "/api/sign" { return true }
		if isDestructive && normalized.hasPrefix("/api/") { return true }

		return false
	}

	/// A token gate that is meaningful when no token is configured.
	///
	/// `nil` or blank `expected` means "no token configured"; callers fall back to
	/// Basic auth in that case. Comparison is length-constant so a wrong guess
	/// cannot be narrowed down character by character.
	static func tokenMatches(expected: String?, provided: String?) -> Bool {
		guard let expected else { return true }
		let expectedTrimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !expectedTrimmed.isEmpty else { return true }
		guard let provided else { return false }
		return WebManagerAuthMiddleware.constantTimeEquals(provided, expectedTrimmed)
	}

	// MARK: - Host and Origin

	/// Names the server answers to, so a request can prove it was addressed here.
	///
	/// `0.0.0.0` is the *bind* address, never something a client can put in a
	/// `Host` header, so it is dropped: the LAN address the certificate was issued
	/// for is what a browser on this network actually types.
	static func allowedHosts(boundHost: String, advertisedHost: String?) -> Set<String> {
		var hosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
		let candidates: [String?] = [boundHost, advertisedHost]
		for candidate in candidates {
			if let host = normalizedHost(candidate), !host.isEmpty, host != "0.0.0.0" {
				hosts.insert(host)
			}
		}
		return hosts
	}

	/// `host[:port]` -> lowercased bare host, IPv6 literals without brackets.
	///
	/// Returns nil for anything that is not an authority at all, so a header
	/// carrying a path, userinfo, whitespace or CR/LF can never be compared as if
	/// it were a hostname.
	static func normalizedHost(_ raw: String?) -> String? {
		var host = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !host.isEmpty else { return nil }
		guard !host.contains(where: { $0 == "/" || $0 == "\\" || $0 == "@" || $0 == "?" || $0 == "#" || $0.isWhitespace }) else {
			return nil
		}
		if host.hasPrefix("[") {
			guard let closing = host.firstIndex(of: "]") else { return nil }
			let inner = String(host[host.index(after: host.startIndex)..<closing])
			return inner.isEmpty ? nil : inner
		}
		if let colon = host.lastIndex(of: ":") {
			// One colon is a port separator; two or more means a bare IPv6 literal.
			guard !String(host[host.startIndex..<colon]).contains(":") else { return host }
			host = String(host[host.startIndex..<colon])
		}
		return host.isEmpty ? nil : host
	}

	/// Whether the `Host` header names this server.
	///
	/// Beyond the explicit names, private-network literals and `.local` Bonjour
	/// names are accepted: they can only resolve on the local network, so a page
	/// on the internet cannot use one to reach this server. A *public* name that
	/// resolves to the LAN address — the DNS-rebinding case — is refused, which is
	/// the whole point of checking this header at all.
	static func isAllowedHostHeader(_ header: String?, allowedHosts: Set<String>) -> Bool {
		guard let host = normalizedHost(header), !host.isEmpty else { return false }
		if allowedHosts.contains(host) { return true }
		if host.hasSuffix(".local") { return true }
		return isPrivateAddressLiteral(host)
	}

	/// Loopback, RFC 1918, link-local and unique-local literals.
	static func isPrivateAddressLiteral(_ host: String) -> Bool {
		let parts = host.split(separator: ".", omittingEmptySubsequences: false)
		if parts.count == 4, parts.allSatisfy({ UInt8(String($0)) != nil }) {
			let octets = parts.compactMap { UInt8(String($0)) }
			guard octets.count == 4 else { return false }
			switch octets[0] {
			case 10, 127: return true
			case 169: return octets[1] == 254
			case 172: return octets[1] >= 16 && octets[1] <= 31
			case 192: return octets[1] == 168
			default: return false
			}
		}
		guard host.contains(":") else { return false }
		return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80")
	}

	/// Whether a request's `Origin` agrees with its `Host`.
	///
	/// No `Origin` header means a non-browser client (curl, WebDAV, a companion
	/// app), which cannot be rebound onto another site and is left alone. A browser
	/// always sends one, and a page loaded from an attacker's origin keeps that
	/// origin even after its DNS answer is rebound to this device — so comparing
	/// the two catches exactly the requests that check cannot.
	static func isAllowedOrigin(_ origin: String?, hostHeader: String?) -> Bool {
		let raw = (origin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		if raw.isEmpty { return true }
		guard let host = normalizedHost(hostHeader), !host.isEmpty else { return false }
		// `Origin: null` comes from a sandboxed iframe or a file: page and names no
		// host, so there is nothing to compare and nothing to trust.
		guard raw.lowercased() != "null", let parsed = URLComponents(string: raw) else { return false }
		guard parsed.scheme?.lowercased() == "https" else { return false }
		guard let originHost = normalizedHost(parsed.host), !originHost.isEmpty else { return false }
		return originHost == host
	}

	/// The mode actually used.
	///
	/// "No password" and "reachable from the network" must never happen by
	/// accident: without credentials the server falls back to loopback unless the
	/// user explicitly opted into unauthenticated network exposure.
	static func effectiveBindMode(
		requested: WebManagerBindMode,
		authActive: Bool,
		allowUnauthenticatedLAN: Bool
	) -> WebManagerBindMode {
		guard requested == .localNetwork else { return .thisDevice }
		return (authActive || allowUnauthenticatedLAN) ? .localNetwork : .thisDevice
	}

	/// Hostname for `effectiveBindMode`, spelled out so the UI and the server
	/// cannot disagree about what is being exposed.
	static func bindHost(_ mode: WebManagerBindMode) -> String { mode.hostname }

	/// 24 random bytes encoded as URL-safe base64 without padding.
	static func generateToken() -> String {
		var bytes = [UInt8](repeating: 0, count: 24)
		guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
			return UUID().uuidString.replacingOccurrences(of: "-", with: "")
		}
		return Data(bytes)
			.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}
}

// MARK: - Settings migration

/// One-time migration for the settings that changed meaning when the Web Manager
/// became authenticated by default.
enum WebManagerSettingsMigration {
	enum Key {
		static let auth = "VexSign.webManager.auth"
		static let authMigrated = "VexSign.webManager.authMigrated"
	}

	/// Switches existing installs to "require a password" exactly once.
	///
	/// - Returns: `true` when an install that had the server open has just been
	///   locked down, so the caller can explain the change instead of silently
	///   altering behaviour.
	@discardableResult
	static func migrateAuthDefaultIfNeeded(defaults: UserDefaults = .standard) -> Bool {
		guard !defaults.bool(forKey: Key.authMigrated) else { return false }

		let hadExplicitChoice = defaults.object(forKey: Key.auth) != nil
		let wasOpen = hadExplicitChoice && !defaults.bool(forKey: Key.auth)

		defaults.set(true, forKey: Key.auth)
		defaults.set(true, forKey: Key.authMigrated)
		return wasOpen
	}
}
