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
