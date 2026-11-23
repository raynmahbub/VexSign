//
//  PackageArchiveType.swift
//  VexSign
//
//  What a chosen file actually is, decided from its bytes instead of its name.
//
//  Import used to look only at the extension, so a `.zip` full of an app was
//  rejected by the picker before it was ever opened, and a file whose name said
//  `.ipa` but whose content was not a ZIP failed deep inside extraction with an
//  unrelated message. The first bytes say which format a file really is, so the
//  decision lives here, in one place, and the picker and the importer agree.
//

import Foundation

enum PackageArchiveType: Equatable {
    /// A ZIP container: an IPA, a TIPA (an IPA renamed for AirDrop) and a plain
    /// `.zip` that holds `Payload/` or an app bundle.
    case zip
    /// A gzip-compressed tar, as shipped by `.tar.gz`/`.tgz` release assets.
    case tarGzip
    /// Not a container VexSign can open.
    case unsupported

    /// Extensions offered by the package pickers.
    ///
    /// Content still decides; this only stops the system picker from greying out
    /// a valid archive. `.tgz` is deliberately absent: a gzipped tar has no
    /// reader here, so offering it in the picker would invite a file that
    /// `rejectionReason(at:)` has to refuse a moment later. It is still
    /// *detected*, because a download or a shared link can deliver one and the
    /// refusal has to name the format.
    static let pickerExtensions = ["ipa", "tipa", "zip"]

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
    /// A file is only worth routing to the app importer when its *content* is a
    /// container that importer can unpack, which is a ZIP. A gzipped tar is
    /// detected and refused with its own message rather than accepted and
    /// failed later.
    static func accepted(at url: URL) -> Bool {
        detect(at: url) == .zip
    }

    /// Why the file at `url` cannot be imported as an app package, or `nil` when
    /// it can.
    ///
    /// The sentences live here so the picker, the shared-file path and
    /// `AppFileHandler` give the same answer for the same bytes. Before this
    /// existed, three call sites each carried their own wording, so the same
    /// `.tar.gz` could be reported as an unsupported format, a broken ZIP or a
    /// failed download depending on which route it arrived on.
    static func rejectionReason(at url: URL) -> String? {
        switch detect(at: url) {
        case .zip:
            return nil
        case .tarGzip:
            return NSLocalizedString(
                "This archive is compressed as .tar.gz, which VexSign cannot unpack. Extract it and import the .ipa or .tipa inside.",
                comment: ""
            )
        case .unsupported:
            return NSLocalizedString(
                "This file is not an IPA, TIPA or ZIP archive. Import the app package exactly as it was downloaded.",
                comment: ""
            )
        case .none:
            return NSLocalizedString(
                "This file could not be read. Copy it to this device again and retry the import.",
                comment: ""
            )
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
