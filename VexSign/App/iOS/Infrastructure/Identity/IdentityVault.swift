//
//  IdentityVault.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation
import Security
import OSLog

/// Non-secret identity preferences retain legacy mirroring. API credentials are
/// Keychain-only; plaintext legacy copies are removed only after successful migration.
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
            do {
                let data = try SecureSecretStore.read(key.account, service: key.service)
                let value = data.map { String(decoding: $0, as: UTF8.self) } ?? _fileValue(key) ?? _defaultsValue(key)
                if let value {
                    try SecureSecretStore.write(Data(value.utf8), account: key.account, service: key.service)
                    _writeFile(key, nil)
                    UserDefaults.standard.removeObject(forKey: key.defaultsKey)
                }
                return value
            } catch {
                Logger.misc.error("Credential migration requires an unlocked Keychain.")
                return nil
            }
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
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
		]

		SecItemAdd(query as CFDictionary, nil)
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
