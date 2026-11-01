//
//  BackupCrypto.swift
//  VexSign
//
//  Created by VexSign Team
//
//  The backup container. Every backup this app writes is encrypted, including the
//  ones the user asked not to password-protect: the payload key is wrapped either
//  by a PBKDF2-derived key from the password or by a random device key held in
//  the Keychain. A file that leaves the device is ciphertext either way
//  (docs/ROADMAP.md).
//
//  Old files still open:
//    "VEXBK2\n" - encrypted, envelope (this version)
//    "VEXBK1\n" - encrypted, password only (earlier versions)
//    "VEXBK0\n" - plaintext (earlier versions; read, and reported as legacy)
//

import Foundation
import CryptoKit
import CommonCrypto
import NimbleExtensions

enum BackupCrypto {
	/// Header of a backup written by this version: always encrypted.
	private static let magic = Data("VEXBK2\n".utf8)
	/// Header of a password-only backup written by an earlier version.
	private static let passwordMagic = Data("VEXBK1\n".utf8)
	/// Header of an unencrypted backup written by an earlier version.
	private static let plainMagic = Data("VEXBK0\n".utf8)

	private static let saltCount = 16
	private static let iterations = 200_000
	/// 12-byte nonce + 32-byte key + 16-byte tag.
	private static let wrappedKeyCount = 60
	/// Keychain account holding the device key that wraps a passwordless backup.
	private static let deviceKeyAccount = "backup.deviceKey"

	/// Shortest password accepted for a backup that contains signing identities.
	static let minimumPasswordLength = 8

	/// What wrapped the payload key.
	private enum Wrap: UInt8 {
		case password = 1
		case device = 2
	}

	enum Failure: LocalizedError, Equatable {
		case badFormat
		case wrongPassword
		case passwordRequired
		case passwordTooShort
		case certificatesNeedPassword
		case deviceBoundBackup
		case cryptoFailed

		var errorDescription: String? {
			switch self {
			case .badFormat:
				String.localized("This file isn't a valid VexSign backup.")
			case .wrongPassword:
				String.localized("Incorrect password or corrupted backup.")
			case .passwordRequired:
				String.localized("This backup needs a password.")
			case .passwordTooShort:
				String.localized("Use at least %lld characters for the backup password.", arguments: Int64(BackupCrypto.minimumPasswordLength))
			case .certificatesNeedPassword:
				String.localized("A backup that includes certificates needs a password of at least %lld characters, because it contains private keys.", arguments: Int64(BackupCrypto.minimumPasswordLength))
			case .deviceBoundBackup:
				String.localized("This backup was encrypted for the device that made it. To open it here, back up with a password instead.")
			case .cryptoFailed:
				String.localized("Backup encryption failed, please try again.")
			}
		}
	}

	// MARK: - Inspection

	/// `true` for a file this app can only read with a credential — which is
	/// every file this version writes.
	static func isEncrypted(_ data: Data) -> Bool {
		data.prefix(magic.count) == magic || data.prefix(passwordMagic.count) == passwordMagic
	}

	static func isEncrypted(_ url: URL) -> Bool {
		do {
			let handle = try FileHandle(forReadingFrom: url)
			defer { try? handle.close() }
			let head = try handle.read(upToCount: magic.count) ?? Data()
			return isEncrypted(head)
		} catch {
			// The answer stays `false` — an unreadable file is not proof of an encrypted container —
			// but `false` on a good backup sends the user down the plaintext restore path, so the
			// reason has to reach the log.
			FileLogger.error(
				"Could not read \(url.lastPathComponent) to check its container: \(error.localizedDescription)",
				category: "backup"
			)
			return false
		}
	}

	/// `true` when the file predates the encrypted container and can be read
	/// without a password. The UI says so before restoring one.
	static func isLegacyPlaintext(_ url: URL) -> Bool {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
		defer { try? handle.close() }
		guard let head = try? handle.read(upToCount: plainMagic.count) else { return false }
		return head == plainMagic
	}

	/// `true` when opening this file needs the user's password. A passwordless
	/// backup made on this device does not.
	static func needsPassword(_ url: URL) -> Bool {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
		defer { try? handle.close() }
		guard let head = try? handle.read(upToCount: magic.count) else { return false }

		// Older password-only files need one; older plaintext files do not.
		if head.prefix(passwordMagic.count) == passwordMagic { return true }
		guard head.prefix(magic.count) == magic else { return false }

		guard let flag = try? handle.read(upToCount: 1),
			  let byte = flag?.first,
			  let wrap = Wrap(rawValue: byte) else {
			return true
		}
		return wrap == .password
	}

	// MARK: - Seal / unseal

	static func seal(_ plaintext: Data, password: String) throws -> Data {
		let contentKey = SymmetricKey(size: .bits256)
		let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)

		let wrap: Wrap
		var salt = Data()
		let wrappingKey: SymmetricKey
		if trimmed.isEmpty {
			wrap = .device
			// Keep the layout identical for both wraps; the device path has no
			// salt because its key is not derived from anything the user knows.
			salt = Data(count: saltCount)
			wrappingKey = try _deviceKey()
		} else {
			wrap = .password
			salt = try _randomBytes(saltCount)
			wrappingKey = try _deriveKey(password: password, salt: salt)
		}

		let contentKeyBytes = contentKey.withUnsafeBytes { Data($0) }
		guard
			let wrapped = try AES.GCM.seal(contentKeyBytes, using: wrappingKey).combined,
			wrapped.count == wrappedKeyCount,
			let payload = try AES.GCM.seal(plaintext, using: contentKey).combined
		else {
			throw Failure.cryptoFailed
		}

		var out = magic
		out.append(wrap.rawValue)
		out.append(salt)
		out.append(wrapped)
		out.append(payload)
		return out
	}

	static func unseal(_ data: Data, password: String) throws -> Data {
		// Old unencrypted container. It still restores, and the caller warns.
		if data.prefix(plainMagic.count) == plainMagic {
			return data.dropFirst(plainMagic.count)
		}

		if data.prefix(passwordMagic.count) == passwordMagic {
			return try _unsealPasswordOnly(data, password: password)
		}

		let saltStart = magic.count + 1
		let wrapStart = saltStart + saltCount
		guard
			data.prefix(magic.count) == magic,
			data.count > wrapStart + wrappedKeyCount,
			let wrap = Wrap(rawValue: data[magic.count])
		else {
			throw Failure.badFormat
		}

		let salt = data.subdata(in: saltStart..<wrapStart)
		let wrapped = data.subdata(in: wrapStart..<(wrapStart + wrappedKeyCount))
		let payload = data.subdata(in: (wrapStart + wrappedKeyCount)..<data.count)

		let wrappingKey: SymmetricKey
		switch wrap {
		case .password:
			guard !password.isEmpty else { throw Failure.passwordRequired }
			wrappingKey = try _deriveKey(password: password, salt: salt)
		case .device:
			// A failed Keychain read (locked, or a different device) is the same
			// answer to the user: this file cannot be opened here.
			guard let key = (try? _deviceKeyIfPresent()) else { throw Failure.deviceBoundBackup }
			wrappingKey = key
		}

		let contentKeyData: Data
		do {
			contentKeyData = try AES.GCM.open(try AES.GCM.SealedBox(combined: wrapped), using: wrappingKey)
		} catch {
			throw wrap == .password ? Failure.wrongPassword : Failure.badFormat
		}

		do {
			return try AES.GCM.open(
				try AES.GCM.SealedBox(combined: payload),
				using: SymmetricKey(data: contentKeyData)
			)
		} catch {
			throw Failure.wrongPassword
		}
	}

	/// Reads the earlier password-only container (salt + one GCM box).
	private static func _unsealPasswordOnly(_ data: Data, password: String) throws -> Data {
		guard data.count > passwordMagic.count + saltCount else { throw Failure.badFormat }
		guard !password.isEmpty else { throw Failure.passwordRequired }
		let saltStart = passwordMagic.count
		let salt = data.subdata(in: saltStart..<(saltStart + saltCount))
		let box = data.subdata(in: (saltStart + saltCount)..<data.count)
		do {
			return try AES.GCM.open(try AES.GCM.SealedBox(combined: box), using: try _deriveKey(password: password, salt: salt))
		} catch {
			throw Failure.wrongPassword
		}
	}

	// MARK: - Keys

	/// The device key that wraps a passwordless backup. Created on first use and
	/// kept in the Keychain, so the file is useless without this device.
	private static func _deviceKey() throws -> SymmetricKey {
		if let existing = try _deviceKeyIfPresent() { return existing }

		let bytes = try _randomBytes(32)
		do {
			try SecureSecretStore.write(bytes, account: deviceKeyAccount)
		} catch {
			throw Failure.cryptoFailed
		}
		return SymmetricKey(data: bytes)
	}

	private static func _deviceKeyIfPresent() throws -> SymmetricKey? {
		guard let data = try SecureSecretStore.read(deviceKeyAccount), data.count == 32 else { return nil }
		return SymmetricKey(data: data)
	}

	private static func _randomBytes(_ count: Int) throws -> Data {
		var bytes = Data(count: count)
		let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
		guard status == errSecSuccess else { throw Failure.cryptoFailed }
		return bytes
	}

	private static func _deriveKey(password: String, salt: Data) throws -> SymmetricKey {
		var derived = [UInt8](repeating: 0, count: 32)
		let pw = Array(password.utf8)
		let status = pw.withUnsafeBytes { pwBuf in
			salt.withUnsafeBytes { saltBuf in
				CCKeyDerivationPBKDF(
					CCPBKDFAlgorithm(kCCPBKDF2),
					pwBuf.baseAddress?.assumingMemoryBound(to: Int8.self), pw.count,
					saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
					CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
					UInt32(iterations),
					&derived, derived.count
				)
			}
		}
		guard Int(status) == kCCSuccess else { throw Failure.cryptoFailed }
		return SymmetricKey(data: Data(derived))
	}
}
