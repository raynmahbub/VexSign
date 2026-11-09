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
// .
//
//  Old files still open:
//    "VEXBK3\n" - chunk-authenticated file stream (current file writer)
//    "VEXBK2\n" - encrypted, whole-buffer envelope
//    "VEXBK1\n" - encrypted, password only (earlier versions)
//    "VEXBK0\n" - plaintext (earlier versions; read, and reported as legacy)
//

import Foundation
import CryptoKit
import CommonCrypto
import NimbleExtensions

enum BackupCrypto {
	/// Header of the legacy whole-buffer API; file backups use streamMagic.
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
    private static let deviceKeyCreationLock = NSLock()

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
        case streamTooLarge
        case legacyTooLarge

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
            case .streamTooLarge:
                String.localized("This backup exceeds the safe streaming-container size limit.")
            case .legacyTooLarge:
                String.localized("This older backup is too large for safe in-memory decryption. Open it with the version that created it and export smaller components.")
			case .cryptoFailed:
				String.localized("Backup encryption failed, please try again.")
			}
		}
	}

	// MARK: - Inspection

	/// `true` for a file this app can only read with a credential — which is
	/// every file this version writes.
	static func isEncrypted(_ data: Data) -> Bool {
		data.prefix(magic.count) == magic || data.prefix(passwordMagic.count) == passwordMagic || data.prefix(streamMagic.count) == streamMagic
	}

	static func isEncrypted(_ url: URL) -> Bool {
		do {
			let handle = try FileHandle(forReadingFrom: url)
			defer { try? handle.close() } // try? ok: preserve the primary operation error
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
		guard let handle = try? FileHandle(forReadingFrom: url) else { return false } // try? ok: magic probe; an unreadable file is simply not this format
		defer { try? handle.close() } // try? ok: preserve the primary operation error
		guard let head = try? handle.read(upToCount: plainMagic.count) else { return false } // try? ok: magic probe; a short read is not this format
		return head == plainMagic
	}

	/// `true` when opening this file needs the user's password. A passwordless
	/// backup made on this device does not.
	static func needsPassword(_ url: URL) -> Bool {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return false } // try? ok: magic probe; an unreadable file is simply not this format
		defer { try? handle.close() } // try? ok: preserve the primary operation error
		guard let head = try? handle.read(upToCount: magic.count) else { return false } // try? ok: magic probe; a short read is not this format

		// Older password-only files need one; older plaintext files do not.
		if head.prefix(passwordMagic.count) == passwordMagic { return true }
		guard head.prefix(magic.count) == magic || head.prefix(streamMagic.count) == streamMagic else { return false }

		guard let flag = try? handle.read(upToCount: 1), // try? ok: magic probe; a missing flag byte is not this format
			  let byte = flag.first,
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
			guard let key = (try? _deviceKeyIfPresent()) else { throw Failure.deviceBoundBackup } // try? ok: failure is surfaced as Failure.deviceBoundBackup
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
        // Concurrent passwordless exports must not overwrite one another's key.
        deviceKeyCreationLock.lock()
        defer { deviceKeyCreationLock.unlock() }
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

// MARK: - File-stream container (VEXBK3)
// The envelope wraps one random content key. Each <=1 MiB record has its own
// AES-GCM tag, deterministic per-file counter nonce, and AAD binding the complete
// envelope, record index and plaintext length. A tagged zero-length record and
// mandatory EOF prevent truncation, appending, reordering and record substitution.
extension BackupCrypto {
    private static let streamMagic = Data("VEXBK3\n".utf8)
    static let streamChunkBytes = 1024 * 1024
    static let maximumStreamBytes: UInt64 = 9 * 1024 * 1024 * 1024
    private static let maximumLegacyFileBytes: UInt64 = 256 * 1024 * 1024
    private static let maximumDataRecords = maximumStreamBytes / UInt64(streamChunkBytes)

    static func sealFile(_ input: URL, to output: URL, password: String) throws {
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() } // try? ok: preserve the primary operation error.
        let contentKey = SymmetricKey(size: .bits256)
        let wrap: Wrap = password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .device : .password
        let salt: Data
        let wrappingKey: SymmetricKey
        if wrap == .device {
            salt = Data(count: saltCount)
            wrappingKey = try _deviceKey()
        } else {
            salt = try _randomBytes(saltCount)
            wrappingKey = try _deriveKey(password: password, salt: salt)
        }
        var prefix = streamMagic
        prefix.append(wrap.rawValue)
        prefix.append(salt)
        guard let wrapped = try AES.GCM.seal(contentKey.withUnsafeBytes { Data($0) },
            using: wrappingKey, authenticating: prefix).combined, wrapped.count == wrappedKeyCount else {
            throw Failure.cryptoFailed
        }
        var header = prefix
        header.append(wrapped)
        try _writeStreamAtomically(to: output) { destination in
            try destination.write(contentsOf: header)
            var index: UInt64 = 0
            var total: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let terminal = try autoreleasepool { () throws -> Bool in
                    let plaintext = try source.read(upToCount: streamChunkBytes) ?? Data()
                    guard UInt64(plaintext.count) <= maximumStreamBytes - total,
                          plaintext.isEmpty || index < maximumDataRecords else { throw Failure.streamTooLarge }
                    total += UInt64(plaintext.count)
                    let length = _streamInteger(UInt64(plaintext.count), bytes: 4)
                    let box = try AES.GCM.seal(plaintext, using: contentKey,
                        nonce: _streamNonce(index), authenticating: header + _streamInteger(index, bytes: 8) + length)
                    try destination.write(contentsOf: length)
                    try destination.write(contentsOf: box.ciphertext)
                    try destination.write(contentsOf: box.tag)
                    return plaintext.isEmpty
                }
                if terminal { break }
                index += 1
            }
        }
    }

    /// Returns the SHA-256 of the authenticated plaintext. No destination is
    /// published until every record, the terminal tag, EOF and close succeed.
    static func unsealFile(_ input: URL, to output: URL, password: String) throws -> String {
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() } // try? ok: preserve the primary operation error.
        let magicBytes = try _streamRead(source, count: streamMagic.count)
        if magicBytes != streamMagic {
            let size = try source.seekToEnd()
            guard size <= maximumLegacyFileBytes else { throw Failure.legacyTooLarge }
            try source.seek(toOffset: 0)
            let plaintext = try unseal(try _streamRead(source, count: Int(size)), password: password)
            try Task.checkCancellation()
            try _writeStreamAtomically(to: output) { try $0.write(contentsOf: plaintext) }
            return SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()
        }
        let envelope = try _streamRead(source, count: 1 + saltCount + wrappedKeyCount)
        guard let wrap = Wrap(rawValue: envelope[0]) else { throw Failure.badFormat }
        let salt = envelope.subdata(in: 1..<(1 + saltCount))
        let prefix = streamMagic + envelope.prefix(1 + saltCount)
        let header = streamMagic + envelope
        let wrappingKey: SymmetricKey
        if wrap == .password {
            guard !password.isEmpty else { throw Failure.passwordRequired }
            wrappingKey = try _deriveKey(password: password, salt: salt)
        } else {
            do {
                guard let key = try _deviceKeyIfPresent() else { throw Failure.deviceBoundBackup }
                wrappingKey = key
            } catch { throw Failure.deviceBoundBackup }
        }
        let contentKey: SymmetricKey
        do {
            let keyBytes = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.suffix(wrappedKeyCount)),
                using: wrappingKey, authenticating: prefix)
            guard keyBytes.count == 32 else { throw Failure.badFormat }
            contentKey = SymmetricKey(data: keyBytes)
        } catch {
            throw wrap == .password ? Failure.wrongPassword : Failure.badFormat
        }
        var digest = SHA256()
        try _writeStreamAtomically(to: output) { destination in
            var index: UInt64 = 0
            var total: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let terminal = try autoreleasepool { () throws -> Bool in
                    let lengthBytes = try _streamRead(source, count: 4)
                    let length = lengthBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    guard length <= UInt64(streamChunkBytes), length <= maximumStreamBytes - total,
                          index <= maximumDataRecords, length == 0 || index < maximumDataRecords else {
                        throw Failure.badFormat
                    }
                    total += length
                    let encrypted = try _streamRead(source, count: Int(length) + 16)
                    let plaintext: Data
                    do {
                        let box = try AES.GCM.SealedBox(nonce: _streamNonce(index),
                            ciphertext: encrypted.prefix(Int(length)), tag: encrypted.suffix(16))
                        plaintext = try AES.GCM.open(box, using: contentKey,
                            authenticating: header + _streamInteger(index, bytes: 8) + lengthBytes)
                    } catch { throw Failure.wrongPassword }
                    if length == 0 {
                        guard (try source.read(upToCount: 1) ?? Data()).isEmpty else { throw Failure.badFormat }
                        return true
                    }
                    digest.update(data: plaintext)
                    try destination.write(contentsOf: plaintext)
                    return false
                }
                if terminal { break }
                index += 1
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func _streamInteger(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private static func _streamNonce(_ index: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data(count: 4) + _streamInteger(index, bytes: 8))
    }

    private static func _streamRead(_ source: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            guard let part = try source.read(upToCount: count - result.count), !part.isEmpty else {
                throw Failure.badFormat
            }
            result.append(part)
        }
        return result
    }

    private static func _writeStreamAtomically(to output: URL, body: (FileHandle) throws -> Void) throws {
        let fm = FileManager.default
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".vexbackup-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.cryptoFailed
        }
        var published = false
        defer {
            if !published {
                do { try fm.removeItem(at: temporary) }
                catch { FileLogger.log("Could not remove incomplete backup stream: \(error)", category: "backup") }
            }
        }
        let destination = try FileHandle(forWritingTo: temporary)
        do {
            try body(destination)
            try Task.checkCancellation()
            try destination.synchronize()
            try destination.close()
            // moveItem fails if a destination exists: never clobber an earlier backup.
            try fm.moveItem(at: temporary, to: output)
            published = true
        } catch {
            try? destination.close() // try? ok: preserve the original encryption/I/O error.
            throw error
        }
    }
}
