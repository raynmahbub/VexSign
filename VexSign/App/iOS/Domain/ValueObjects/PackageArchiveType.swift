//
//  PackageArchiveType.swift
//  VexSign
//
//  What a chosen file actually is, decided from its bytes instead of its name.
//
//  Import used to look only at the extension: a `.zip` full of an app was
//  rejected before it was ever opened, and a `.tipa` was assumed to be a zip.
//  Both guesses are avoidable — the first four bytes say which format the file
//  really is — so the decision lives here, in one place, and the picker and the
//  importer agree on it.
//

import Foundation

enum PackageArchiveType: Equatable {
    /// A ZIP container: IPA, TIPA and a plain `.zip` that holds `Payload/`.
    case zip
    /// A gzip-compressed tar, as shipped by `.tar.gz`/`.tgz` release assets.
    case tarGzip
    /// Not a container VexSign can open.
    case unsupported

    /// Extensions offered by the package pickers. Content still decides; this
    /// only stops the system picker from greying out a valid archive.
    static let pickerExtensions = ["ipa", "tipa", "zip", "tgz"]

    /// Identifies an archive from its leading bytes.
    ///
    /// `nil` means the file could not be read at all; the caller reports that
    /// separately from "read, but not a container we support".
    static func detect(at url: URL) -> PackageArchiveType? {
        // Both optional reads below are the contract of `detect`: an unreadable
        // file is `nil`, an unreadable header is "not a container", and neither is
        // an error the caller could act on differently.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil } // try? ok: nil already means "could not read"
        defer { try? handle.close() } // try? ok: closing a read-only probe cannot fail in a way that matters
        guard let header = try? handle.read(upToCount: 4), header.count >= 2 else { return .unsupported } // try? ok: short read is "unsupported"
        let bytes = [UInt8](header)
        if bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B,
           bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07 {
            return .zip
        }
        if bytes[0] == 0x1F, bytes[1] == 0x8B { return .tarGzip }
        return .unsupported
    }

    /// The extension is a hint for the file picker, never the decision.
    ///
    /// A `.zip` is only worth offering when its content is a container we can
    /// open, so callers pass the detected type rather than the suffix.
    static func accepted(at url: URL) -> Bool {
        switch detect(at: url) {
        case .zip, .tarGzip: true
        case .unsupported, nil: false
        }
    }

    /// Whether this container can carry an application payload.
    ///
    /// Plain ZIP and TIPA archives are read by the IPA extractor; a gzipped tar
    /// has no reader here, so it is refused by name instead of failing later
    /// with an unrelated CRC or "not a zip" error.
    var canCarryAppPayload: Bool {
        self == .zip
    }
}
