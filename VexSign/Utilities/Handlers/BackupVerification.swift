//
//  BackupVerification.swift
//  VexSign
//
//  Does the file on disk still hold what was written?
//
//  `makeBackup` produced a sealed container and returned its URL. Returning is not the same as
//  succeeding: a full disk, a short write or a filesystem that dropped the tail leaves a file
//  whose header looks right and whose last chunk does not decrypt. The user finds out when they
//  try to restore — on a new device, after the old one is gone.
//
//  So the container is opened again before the workflow reports success. That costs one extra
//  read of the file, which is the price of the only claim that matters: the bytes on disk decrypt
//  to exactly the bytes that were packed.
//
//  This is verification, not encryption. The authenticity comes from the AES-GCM tags the
//  container already carries; the digest only proves the *same* plaintext came back out.
//

import CryptoKit
import Foundation
import NimbleExtensions

enum BackupVerification {
    enum Failure: LocalizedError, Equatable {
        /// The container was never written, or vanished before it could be read.
        case missingContainer
        /// The container decrypted, but to something else than what was packed.
        case digestMismatch

        var errorDescription: String? {
            switch self {
            case .missingContainer:
                return .localized("The backup could not be saved. No file was produced.")
            case .digestMismatch:
                return .localized("The backup did not verify after it was written. Delete it and try again.")
            }
        }
    }

    struct Result: Equatable {
        /// SHA-256 of the recovered plaintext, which must equal the digest taken before sealing.
        let plaintextSHA256: String
        /// Bytes on disk. Compared against the size observed while sealing.
        let sealedBytes: Int64
    }

    /// Streaming SHA-256 of a file, without loading it into memory.
    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() } // try? ok: preserve the primary read error
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reopens a just-sealed container and proves it decrypts to the packed bytes.
    ///
    /// - Parameters:
    ///   - expectedPlaintextSHA256: digest of the archive taken *before* sealing.
    ///   - password: the same password (or empty string for the device wrap) used to seal.
    ///   - scratch: a directory the recovery file may be written into and removed from.
    static func verifySealedContainer(
        at file: URL,
        expectedPlaintextSHA256: String,
        password: String,
        scratch: URL
    ) throws -> Result {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { throw Failure.missingContainer }
        let attributes = try manager.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw Failure.missingContainer }

        let recovered = scratch.appendingPathComponent("verify-\(UUID().uuidString).zip")
        defer { try? manager.removeItem(at: recovered) } // try? ok: the verification result is what matters, not the cleanup

        // `unsealFile` throws on a bad tag, so a short write or a tampered chunk fails here
        // rather than on the user's next device.
        let actual = try BackupCrypto.unsealFile(file, to: recovered, password: password)
        guard actual == expectedPlaintextSHA256 else { throw Failure.digestMismatch }

        // The returned digest is over the decrypted bytes; hashing the recovered file as well
        // proves the write from `unsealFile` itself was complete.
        guard try digest(of: recovered) == expectedPlaintextSHA256 else { throw Failure.digestMismatch }

        return Result(plaintextSHA256: actual, sealedBytes: size)
    }
}
