import Foundation
import Compression

/// Apple Compression raw-DEFLATE decoding, never permissive archive extraction.
/// Exact input consumption, declared output length, CRC and progress are required.
/// Native API/ZIP dialect compatibility still needs execution in the test phase.
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
            output = try inflate(archive, range: range, expectedCount: entry.expandedCount)
        }
        try Task.checkCancellation()
        guard try crc32(output) == entry.crc32 else { throw Failure.checksumMismatch }
        return output
    }

    private static func inflate(_ data: Data, range: Range<Int>, expectedCount: Int) throws -> Data {
        let capacity = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw Failure.decompressionFailed }
            let source = base.advanced(by: range.lowerBound)
            var stream = compression_stream(dst_ptr: destination, dst_size: capacity,
                src_ptr: source, src_size: range.count, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw Failure.decompressionFailed
            }
            defer { compression_stream_destroy(&stream) }
            // Init owns state, not caller buffers. Assign explicitly after init.
            stream.src_ptr = source; stream.src_size = range.count
            stream.dst_ptr = destination; stream.dst_size = capacity
            var output = Data()
            while true {
                try Task.checkCancellation()
                let inputBefore = stream.src_size
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else { throw Failure.decompressionFailed }
                let produced = capacity - stream.dst_size
                guard produced >= 0, produced <= expectedCount - output.count else { throw Failure.decompressionFailed }
                if produced > 0 { output.append(destination, count: produced) }
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0, output.count == expectedCount else { throw Failure.decompressionFailed }
                    return output
                }
                guard stream.src_size < inputBefore || produced > 0 else { throw Failure.decompressionFailed }
                stream.dst_ptr = destination; stream.dst_size = capacity
            }
        }
    }
}
