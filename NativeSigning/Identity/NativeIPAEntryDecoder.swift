import Foundation
import zlib

/// zlib raw-DEFLATE decoding, never permissive archive extraction.
/// Compression.framework may consume trailing bytes through read-ahead; zlib's
/// exact remaining-input count is required at the first stream end.
/// Exact input consumption, declared output length, CRC and progress are required.
struct NativeIPAEntryDecoder {
    enum Failure: Error, Equatable { case invalidEntry, decompressionFailed, checksumMismatch }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
        return value
    }
    static func crc32(_ data: Data) throws -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for (index, byte) in data.enumerated() {
            if index & 65535 == 0 { try Task.checkCancellation() }
            crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }

    static func decode(archive: Data, entry: NativeIPAArchiveIndex.Entry) throws -> Data {
        try Task.checkCancellation()
        let range = entry.compressedRange
        guard range.lowerBound >= 0, range.upperBound <= archive.count,
              range.count <= Int(uInt.max),
              entry.expandedCount >= 0, entry.expandedCount <= 128 * 1024 * 1024,
              entry.expandedCount <= max(1, range.count) * 250,
              entry.method == 0 || entry.method == 8 else { throw Failure.invalidEntry }
        let output: Data
        if entry.method == 0 {
            guard range.count == entry.expandedCount else { throw Failure.invalidEntry }
            let lower = archive.index(archive.startIndex, offsetBy: range.lowerBound)
            let upper = archive.index(lower, offsetBy: range.count)
            output = Data(archive[lower..<upper])
        } else {
            guard !range.isEmpty else { throw Failure.decompressionFailed }
            output = try inflateRaw(archive, range: range, expectedCount: entry.expandedCount)
        }
        try Task.checkCancellation()
        guard try crc32(output) == entry.crc32 else { throw Failure.checksumMismatch }
        return output
    }

    private static func inflateRaw(_ data: Data, range: Range<Int>, expectedCount: Int) throws -> Data {
        let capacity = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw Failure.decompressionFailed }
            let source = base.advanced(by: range.lowerBound)
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw Failure.decompressionFailed
            }
            defer { inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer(mutating: source)
            stream.avail_in = uInt(range.count)
            stream.next_out = destination
            stream.avail_out = uInt(capacity)
            var output = Data()
            while true {
                try Task.checkCancellation()
                let inputBefore = stream.avail_in
                let status = zlib.inflate(&stream, Z_NO_FLUSH)
                guard status == Z_OK || status == Z_STREAM_END else { throw Failure.decompressionFailed }
                let produced = capacity - Int(stream.avail_out)
                guard produced >= 0, produced <= expectedCount - output.count else { throw Failure.decompressionFailed }
                if produced > 0 { output.append(destination, count: produced) }
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, Int(stream.total_in) == range.count, output.count == expectedCount else { throw Failure.decompressionFailed }
                    return output
                }
                guard stream.avail_in < inputBefore || produced > 0 else { throw Failure.decompressionFailed }
                stream.next_out = destination; stream.avail_out = uInt(capacity)
            }
        }
    }
}
