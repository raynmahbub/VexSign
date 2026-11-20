//
//  IdentityVault.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation
import Security
import OSLog

/// Identity values, stored Keychain-first with a plaintext fallback for the ones
/// the app treats as preferences. API credentials are Keychain-only; plaintext
/// legacy copies are removed only after a successful migration.
///
/// The device UUID and premium flags are mirrored into `identity.json` and
/// `UserDefaults` as a durability fallback. That mirror is deliberate — losing
/// the UUID means losing the entitlement — but it is also a bearer credential:
/// `GET /api/urls` accepts the UUID on its own. Anything that reads the container
/// or a decrypted backup can therefore redeem it, so these values are never
/// backed up (`BackupManager.isCredentialSettingKey`) and never stored with a
/// migratable Keychain accessibility class.
enum IdentityVault {
	enum Key: String {
		case deviceUUID
		case premiumActive
		case premiumURLs
		case premiumAPIKey

		var service: String {
			switch self {
			case .deviceUUID: return "com.vexsign.deviceuuid"
			case .premiumActive, .premiumURLs, .premiumAPIKey: return "com.vexsign.premium"
			}
		}

		var account: String {
			switch self {
			case .deviceUUID: return "deviceUUID"
			case .premiumActive: return "isPremium"
			case .premiumURLs: return "premiumURLs"
			case .premiumAPIKey: return "apiKey"
			}
		}

		var defaultsKey: String { "VexSign.vault.\(rawValue)" }
	}

	private static let _lock = NSLock()
	private static var _cache: [Key: String] = [:]

	static func read(_ key: Key) -> String? {
		_lock.lock()
		defer { _lock.unlock() }

		if key == .premiumAPIKey {
            // A read must answer from whichever tier already holds the value. This
            // used to re-write the Keychain on every call inside the same `do`
            // block, so a write that failed (a locked device returns
            // errSecInteractionNotAllowed) discarded a successful read and
            // reported "no key": premium repository auth silently disappeared
            // from background refreshes that run while the device is locked.
            let stored = (try? SecureSecretStore.read(key.account, service: key.service)) // try? ok: an unavailable Keychain falls through to the plaintext fallback tiers below
                .flatMap { String(data: $0, encoding: .utf8) }
            guard let value = stored ?? _fileValue(key) ?? _defaultsValue(key) else { return nil }

            // Retire a legacy plaintext copy once, and only when the Keychain
            // answered without it. A failure here is a migration problem, not a
            // read problem, so the value still reaches the caller and the copy is
            // retired by a later read.
            if stored == nil {
                do {
                    try SecureSecretStore.write(Data(value.utf8), account: key.account, service: key.service)
                    _writeFile(key, nil)
                    UserDefaults.standard.removeObject(forKey: key.defaultsKey)
                } catch {
                    Logger.misc.error("Credential migration needs an unlocked Keychain; serving the stored value.")
                }
            }
            return value
        }
        if let cached = _cache[key] { return cached }

		let tiers = [_keychainValue(key), _fileValue(key), _defaultsValue(key)]
		guard let value = tiers.compactMap({ $0 }).first else { return nil }

		if tiers.contains(where: { $0 != value }) {
			_writeAllTiers(key, value)
		}

		_cache[key] = value
		return value
	}

	static func write(_ key: Key, _ value: String) {
		_lock.lock()
		defer { _lock.unlock() }

		if key == .premiumAPIKey {
            do {
                try SecureSecretStore.write(Data(value.utf8), account: key.account, service: key.service)
                _writeFile(key, nil)
                UserDefaults.standard.removeObject(forKey: key.defaultsKey)
            } catch { Logger.misc.error("Unable to save API credential to Keychain.") }
            return
        }
        _cache[key] = value
        _writeAllTiers(key, value)
	}

	static func delete(_ key: Key) {
		_lock.lock()
		defer { _lock.unlock() }

		_cache[key] = nil
		_deleteKeychainValue(key)
		_writeFile(key, nil)
		UserDefaults.standard.removeObject(forKey: key.defaultsKey)
	}

	private static func _writeAllTiers(_ key: Key, _ value: String) {
		_writeKeychainValue(key, value)
		_writeFile(key, value)
		UserDefaults.standard.set(value, forKey: key.defaultsKey)
	}

	// MARK: - Keychain Tier

	private static func _keychainValue(_ key: Key) -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: key.service,
			kSecAttrAccount as String: key.account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne
		]

		var result: AnyObject?
		guard
			SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
			let data = result as? Data
		else {
			return nil
		}

		return String(data: data, encoding: .utf8)
	}

	private static func _writeKeychainValue(_ key: Key, _ value: String) {
		guard let data = value.data(using: .utf8) else { return }

		_deleteKeychainValue(key)

		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: key.service,
			kSecAttrAccount as String: key.account,
			kSecValueData as String: data,
			// This-device-only. The device UUID is the premium entitlement the
			// server accepts on its own (`GET /api/urls`), so it must not ride in
			// an encrypted backup or migrate to a replacement device. The item is
			// deleted and re-added on every write, so an install that stored it
			// with the old non-`ThisDeviceOnly` constant is upgraded on its next
			// write without a migration pass.
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		]

		// The previous item was just deleted, so a failure here leaves the value
		// only in the plaintext fallback tiers. Record it: otherwise the next
		// launch can mint a fresh UUID (and lose the entitlement) without a trace.
		let status = SecItemAdd(query as CFDictionary, nil)
		if status != errSecSuccess {
			Logger.misc.error("Identity vault could not store \(key.rawValue) in the Keychain (status \(status)); the plaintext fallback is in use.")
		}
	}

	private static func _deleteKeychainValue(_ key: Key) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: key.service,
			kSecAttrAccount as String: key.account
		]

		SecItemDelete(query as CFDictionary)
	}

	// MARK: - File Tier

	private static var _fileURL: URL? {
		guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
			return nil
		}

		let directory = support.appendingPathComponent("VexSign", isDirectory: true)

		if !FileManager.default.fileExists(atPath: directory.path) {
			try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		}

		return directory.appendingPathComponent("identity.json")
	}

	private static func _fileContents() -> [String: String] {
		guard
			let url = _fileURL,
			let data = try? Data(contentsOf: url),
			let contents = try? JSONDecoder().decode([String: String].self, from: data)
		else {
			return [:]
		}

		return contents
	}

	private static func _fileValue(_ key: Key) -> String? {
		_fileContents()[key.rawValue]
	}

	private static func _writeFile(_ key: Key, _ value: String?) {
		guard let url = _fileURL else { return }

		var contents = _fileContents()
		contents[key.rawValue] = value

		guard let data = try? JSONEncoder().encode(contents) else { return }
		try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
	}

	// MARK: - UserDefaults Tier

	private static func _defaultsValue(_ key: Key) -> String? {
		UserDefaults.standard.string(forKey: key.defaultsKey)
	}
}
