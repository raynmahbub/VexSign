//
//  ArchiveFormat.swift
//  VexSign
//
//  One list of the compressions VexSign can unpack, and one place that recognises them.
//
//  Two hand-maintained lists used to describe the same fact: `_detectCompression` mapped magic
//  bytes to a format, and `DebianDataMember.select` listed the `.deb` members by name. They had
//  already drifted — zstd was accepted by neither, and once it was added to one, a `.deb` could
//  name a member the detector did not know. Both now read this type, and `ArchiveFormatTests`
//  asserts that a member the selector accepts always resolves to a format the detector can
//  decode.
//

import Foundation

/// A compression VexSign decodes in-process. `tar` is not here: an uncompressed tar is unpacked by
/// `SWCompression`, and `extractFile` decides that by name and by the `ustar` magic.
enum ArchiveFormat: String, CaseIterable, Sendable {
    case xz
    case lzma
    case gzip
    case bzip2
    case zstd

    /// The file extensions this format arrives with, in the order a message should list them.
    var fileExtensions: [String] {
        switch self {
        case .xz: return ["xz"]
        case .lzma: return ["lzma"]
        case .gzip: return ["gz"]
        case .bzip2: return ["bz2"]
        case .zstd: return ["zst"]
        }
    }

    /// The leading bytes that identify this format; `nil` when the format has no fixed magic
    /// (raw `.lzma` starts differently depending on its encoder, so only the extension knows).
    var magicPrefix: [UInt8]? {
        switch self {
        case .xz: return [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
        case .gzip: return [0x1F, 0x8B]
        case .bzip2: return [0x42, 0x5A, 0x68]
        case .zstd: return [0x28, 0xB5, 0x2F, 0xFD]
        case .lzma: return nil
        }
    }

    /// Detects by magic bytes first, because `.deb` payloads are routinely mislabelled, then by
    /// the extension only for the format that has no magic.
    static func detect(_ data: Data, extensionHint ext: String) -> ArchiveFormat? {
        let head = [UInt8](data.prefix(6))
        for format in allCases {
            guard let magic = format.magicPrefix, head.count >= magic.count else { continue }
            if Array(head.prefix(magic.count)) == magic { return format }
        }
        let hint = ext.lowercased()
        return allCases.first { $0.fileExtensions.contains(hint) }
    }

    /// Every `.deb` data member VexSign accepts.
    ///
    /// `data.tar` is first because an uncompressed payload needs no decoder at all; the rest are
    /// this type's own extensions, so adding a format is one edit in one file. The order is the
    /// declaration order above, which keeps diffs and test failures readable.
    static var debianDataMembers: [String] {
        ["data.tar"] + allCases.compactMap(\.fileExtensions.first).map { "data.tar." + $0 }
    }

    /// The compression a `.deb` data member name uses, or `nil` when the name is not accepted.
    static func debianMember(_ name: String) -> ArchiveFormat? {
        guard name.hasPrefix("data.tar.") else { return nil }
        let suffix = String(name.dropFirst("data.tar.".count))
        return allCases.first { $0.fileExtensions.contains(suffix) }
    }
}
