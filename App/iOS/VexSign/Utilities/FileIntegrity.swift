//
//  FileIntegrity.swift
//  VexSign
//
//  SHA-256 helpers for IPA/archive integrity. Downloaded packages are hashed and
//  logged automatically; File Manager adds "Copy SHA-256" and "Verify Hash…" so a
//  file can be checked against a hash the source published.
//

import Foundation
import CryptoKit

enum FileIntegrity {
	/// Streaming SHA-256 — chunks the file so multi-GB IPAs never load into memory.
	static func sha256(of url: URL) -> String? {
        do { return try sha256(of: url, cancellationCheck: {}) }
        catch { return nil } // A non-cancellable caller represents unreadable input as nil.
    }

    /// Cancellation checkpoints are outside I/O catch blocks and are never converted into a digest.
    static func sha256(of url: URL, cancellationCheck: () throws -> Void) throws -> String? {
        try cancellationCheck()
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { return nil }
        defer { try? handle.close() } // try? ok: read-only handle teardown
        var hasher = SHA256()
        var unreadable = false
        while true {
            try cancellationCheck()
            // `FileHandle.read(upToCount:)` returns an autoreleased buffer. Callers hash on a
            // background queue or task that has no pool of its own, so without draining one
            // per chunk every megabyte read stayed alive until the whole file had been hashed
            // — a 500 MB IPA held about 500 MB at once. `BackupCrypto` drains the same way.
            let finished: Bool = autoreleasepool {
                let chunk: Data
                do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() }
                catch { unreadable = true; return true }
                if chunk.isEmpty { return true }
                hasher.update(data: chunk)
                return false
            }
            if finished { break }
        }
        if unreadable { return nil }
        try cancellationCheck()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

	/// True when the file's SHA-256 equals `expected` (case- and prefix-tolerant).
	static func matches(_ url: URL, expected: String) -> Bool {
		guard let actual = sha256(of: url) else { return false }
		return actual == normalize(expected)
	}

	/// Trims, lowercases and strips an optional "sha256:" prefix from a pasted hash.
	static func normalize(_ hash: String) -> String {
		var hash = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if hash.hasPrefix("sha256:") { hash.removeFirst("sha256:".count) }
		return hash
	}
}
