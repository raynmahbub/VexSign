//
//  CompanionSecretStore.swift
//  VexSign
//
//  Keychain storage for the two companion credentials the Apple TV and Vision Pro
//  apps hold: the Web Manager password and its API token.
//
//  Both used to be written to `UserDefaults`, which put a reusable password and a
//  bearer-equivalent token in every preferences dump, iTunes/Finder backup and
//  diagnostics bundle the app can produce — the same mistake the in-app Web
//  Manager and the cloud-signing client had already stopped making. This file is
//  the companion-side equivalent of `App/iOS/VexSign/Security/SecureSecretStore.swift`,
//  written separately because that one also carries certificate sealing and
//  iOS-only error types, while this file is compiled into the tvOS and visionOS
//  targets too.
//
//  Foundation and Security only, no UIKit and no CryptoKit: the companions must
//  stay portable (see Documentation/Engineering/PLATFORMS.md).
//

import Foundation
import Security

/// A credential write or read that the Keychain refused.
///
/// `locked` is deliberately distinct from the rest: it is the one failure that
/// resolves by itself when the device is unlocked, and the UI says so instead of
/// asking the user to re-enter a credential that is still stored correctly.
enum CompanionSecretError: Error {
	case locked
	case unavailable
	case failed(OSStatus)

	/// Human-readable, and never derived from a secret value.
	var message: String {
		switch self {
		case .locked:
			return "The Keychain is locked. Unlock the device and try again; the saved credential has not been discarded."
		case .unavailable:
			return "The Keychain is unavailable right now. The connection settings are kept for this session only."
		case .failed:
			return "The credential could not be saved to the Keychain."
		}
	}

	static func classify(_ status: OSStatus) -> CompanionSecretError {
		switch status {
		case errSecInteractionNotAllowed, errSecNotAvailable:
			return .locked
		case errSecAuthFailed, errSecUserCanceled, errSecDecode:
			return .unavailable
		default:
			return .failed(status)
		}
	}
}

/// The companion's credentials, addressed by account name inside one service.
enum CompanionSecretStore {
	static let service = "com.vexsign.companion"

	/// Keychain account names. Kept as constants so a rename cannot silently
	/// orphan a stored credential.
	enum Account {
		static let password = "webManager.password"
		static let apiToken = "webManager.apiToken"
	}

	static func read(_ account: String) throws -> String? {
		var query = base(account)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne

		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw CompanionSecretError.classify(status) }
		guard let data = result as? Data else { throw CompanionSecretError.failed(errSecDecode) }
		return String(decoding: data, as: UTF8.self)
	}

	static func write(_ value: String, account: String) throws {
		let query = base(account)
		let attributes: [String: Any] = [
			kSecValueData as String: Data(value.utf8),
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		]

		var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if status == errSecItemNotFound {
			status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
			if status == errSecDuplicateItem {
				status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
			}
		}
		guard status == errSecSuccess else { throw CompanionSecretError.classify(status) }
	}

	static func delete(_ account: String) throws {
		let status = SecItemDelete(base(account) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw CompanionSecretError.classify(status)
		}
	}

	/// Reads a credential that may still live in `UserDefaults` from an earlier build.
	///
	/// The plaintext copy is removed **only after** the Keychain write succeeded, so a
	/// locked Keychain on the first launch after upgrading keeps a working credential
	/// instead of losing it — the caller sees the thrown error, keeps using the legacy
	/// value for this session, and the next launch migrates it.
	static func migrate(
		legacyKey: String,
		account: String,
		defaults: UserDefaults = .standard
	) throws -> String {
		if let stored = try read(account) {
			// Finish an interrupted migration: the secure copy exists, so the plaintext
			// one is redundant.
			defaults.removeObject(forKey: legacyKey)
			return stored
		}

		guard let legacy = defaults.string(forKey: legacyKey) else { return "" }
		try write(legacy, account: account)
		defaults.removeObject(forKey: legacyKey)
		return legacy
	}

	private static func base(_ account: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecAttrSynchronizable as String: false
		]
	}
}
