//
//  ZstdDecompression.swift
//  VexSign
//
//  Zstandard decoding for archive payloads, backed by `VexZstd.c`.
//
//  iOS has no zstd API — `Compression` covers LZMA, LZFSE, LZ4 and zlib, and SWCompression
//  covers none of them for zstd — so a `.deb` whose payload is `data.tar.zst` had no path
//  through VexSign at all and was refused as an unsupported format. Debian and the package
//  repositories that matter have moved to zstd for `data.tar`, so this is the format a modern
//  tweak arrives in.
//

import Foundation

/// Decodes a zstd frame with a hard ceiling on the result.
///
/// The ceiling is not a formality: a `.deb` payload is untrusted input, and zstd reaches
/// ratios in the thousands. `extractFile`'s `maximumExpandedBytes` is the same bound the
/// gzip/xz/bzip2 paths apply, and here it is enforced *during* decoding rather than after,
/// so a hostile archive cannot allocate its way past it first.
enum ZstdDecompression {
    /// - Parameters:
    ///   - data: One zstd frame, or several concatenated frames (a skippable frame is
    ///     skipped, as the format requires).
    ///   - limit: The most bytes this call may produce.
    /// - Throws: `ArchiveExtractionError.expandedTooLarge` when the frame declares or
    ///   produces more than `limit`, `TweakHandlerError.decompressionFailed` when the input
    ///   is malformed, truncated, or fails its XXH64 checksum.
    static func decompress(_ data: Data, limit: Int) throws -> Data {
        precondition(limit > 0, "A decompression limit is required for untrusted payloads.")
        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status: Int32 = data.withUnsafeBytes { raw in
            vex_zstd_decode(
                raw.bindMemory(to: UInt8.self).baseAddress,
                data.count,
                limit,
                &buffer,
                &length
            )
        }

        guard status == 0, let bytes = buffer else {
            // -2 is the ceiling; -1 is everything else the decoder can refuse.
            if status == -2 { throw ArchiveExtractionError.expandedTooLarge(Int64(limit)) }
            let detail = String(cString: vex_zstd_last_error())
            throw TweakHandlerError.decompressionFailed(detail)
        }
        defer { vex_zstd_free(bytes) }

        return Data(bytes: bytes, count: length)
    }

    /// Whether `data` starts like a zstd frame (magic `28 B5 2F FD`, little endian).
    static func looksLikeZstd(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = [UInt8](data.prefix(4))
        return magic == [0x28, 0xB5, 0x2F, 0xFD]
    }
}
