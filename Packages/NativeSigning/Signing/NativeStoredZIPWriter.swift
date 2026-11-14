import Foundation

/// Deterministic bounded ZIP32 transport encoding, NOT signed-artifact authority.
/// In-memory regular files/directories only; no extraction, symlinks, URLs or key
/// material. A future artifact sealer must verify complete signed output first.
struct NativeStoredZIPWriter {
    struct Entry: Sendable {
        let path: String
        let bytes: Data
        let executable: Bool
        init(path: String, bytes: Data, executable: Bool = false) {
            self.path = path; self.bytes = bytes; self.executable = executable
        }
    }
    static func encode(_ entries: [Entry]) throws -> Data {
        try Task.checkCancellation()
        guard !entries.isEmpty, entries.count <= 10000 else { throw NativeIPAArchiveError.resourceLimit }
        let limit = 128 * 1024 * 1024
        var budget = 22
        for entry in entries {
            let count = entry.path.utf8.count
            guard count > 0, count <= 1024, entry.path.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }),
                  !entry.path.hasSuffix("/") || (entry.bytes.isEmpty && !entry.executable) else { throw NativeIPAArchiveError.unsafePath }
            let overhead = 76 + 2 * count
            guard overhead <= limit - budget, entry.bytes.count <= limit - budget - overhead else { throw NativeIPAArchiveError.resourceLimit }
            budget += overhead + entry.bytes.count
        }
        let ordered = entries.sorted { $0.path < $1.path }
        var output = Data(); var central = Data()
        func le(_ value: Int, _ count: Int = 4) -> Data {
            Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        for entry in ordered {
            try Task.checkCancellation()
            let name = Data(entry.path.utf8); let offset = output.count
            let crc = Int(try NativeIPAEntryDecoder.crc32(entry.bytes))
            // Constant DOS timestamp 1980-01-01; no wall clock/extra fields.
            output += le(0x04034b50) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(33, 2)
            output += le(crc) + le(entry.bytes.count) + le(entry.bytes.count) + le(name.count, 2) + le(0, 2)
            output += name; output += entry.bytes
            let directory = entry.path.hasSuffix("/")
            let mode = directory ? 0x41ed : (entry.executable ? 0x81ed : 0x81a4)
            central += le(0x02014b50) + le(0x0314, 2) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(33, 2)
            central += le(crc) + le(entry.bytes.count) + le(entry.bytes.count) + le(name.count, 2)
            central += le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le((mode << 16) | (directory ? 16 : 0)) + le(offset) + name
        }
        let start = output.count
        output += central
        output += le(0x06054b50) + le(0, 2) + le(0, 2) + le(ordered.count, 2) + le(ordered.count, 2) + le(central.count) + le(start) + le(0, 2)
        guard output.count == budget else { throw NativeIPAArchiveError.invalidArchive }
        // Reuse the independent strict namespace/index reader, then decode and
        // CRC-check every generated record before returning any transport bytes.
        let index = try NativeIPAArchiveIndex.inspect(output)
        guard index.entries.count == ordered.count else { throw NativeIPAArchiveError.invalidArchive }
        for (record, source) in zip(index.entries, ordered) {
            try Task.checkCancellation()
            guard record.path == (source.path.hasSuffix("/") ? String(source.path.dropLast()) : source.path),
                  try NativeIPAEntryDecoder.decode(archive: output, entry: record) == source.bytes else { throw NativeIPAArchiveError.invalidArchive }
        }
        return output
    }
}
