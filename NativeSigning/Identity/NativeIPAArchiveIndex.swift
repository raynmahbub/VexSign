import Foundation

public enum NativeIPAArchiveError: Error, Equatable, Sendable {
    case invalidArchive, unsupportedFormat, resourceLimit, unsafePath, unsupportedLayout
}

/// Complete ZIP32 record/namespace inventory, NOT decompression/CRC/content
/// validation or signing authority. No extraction, filesystem writes or URLs.
/// Strict subset: one disk, stored/deflate, ASCII paths, selected inert extras;
/// no encryption, ZIP64, prepended stubs, unexplained gaps or alternate names.
struct NativeIPAArchiveIndex: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Entry: Sendable {
        let path: String
        let isDirectory: Bool
        let method: Int
        let crc32: UInt32
        let compressedRange: Range<Int>
        let expandedCount: Int
    }
    let entries: [Entry]
    let archiveSHA256: String
    private init(entries: [Entry], archiveSHA256: String) { self.entries = entries; self.archiveSHA256 = archiveSHA256 }
    var description: String { "NativeIPAArchiveIndex(redacted; content unverified)" }
    var debugDescription: String { description }

    static func inspect(_ data: Data) throws -> Self {
        try Task.checkCancellation()
        guard data.count >= 22 else { throw NativeIPAArchiveError.invalidArchive }
        guard data.count <= 128 * 1024 * 1024 else { throw NativeIPAArchiveError.resourceLimit }
        let entries = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) throws -> [Entry] in
            func u16(_ p: Int) throws -> Int {
                guard p >= 0, p <= bytes.count - 2 else { throw NativeIPAArchiveError.invalidArchive }
                return Int(bytes[p]) | Int(bytes[p + 1]) << 8
            }
            func u32(_ p: Int) throws -> Int {
                guard p >= 0, p <= bytes.count - 4 else { throw NativeIPAArchiveError.invalidArchive }
                return Int(bytes[p]) | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]) << 16 | Int(bytes[p + 3]) << 24
            }
            func checkedRange(_ start: Int, _ length: Int, end: Int) throws -> Range<Int> {
                guard start >= 0, start <= end, end <= bytes.count, length >= 0, length <= end - start else { throw NativeIPAArchiveError.invalidArchive }
                return start..<(start + length)
            }
            func extras(_ range: Range<Int>) throws {
                var p = range.lowerBound; var seen = Set<Int>()
                while p < range.upperBound {
                    guard range.upperBound - p >= 4 else { throw NativeIPAArchiveError.invalidArchive }
                    let kind = try u16(p); let size = try u16(p + 2)
                    guard seen.insert(kind).inserted else { throw NativeIPAArchiveError.invalidArchive }
                    // Extended timestamp / Unix UID-GID only. Neither influences
                    // paths, file kind, sizes, ownership or permissions here.
                    guard kind == 0x5455 || kind == 0x7875 else { throw NativeIPAArchiveError.unsupportedFormat }
                    let payload = try checkedRange(p + 4, size, end: range.upperBound)
                    p = payload.upperBound
                }
            }
            var endings: [Int] = []
            for p in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
                if p & 4095 == 0 { try Task.checkCancellation() }
                if try u32(p) == 0x06054b50 {
                    let comment = try u16(p + 20)
                    if p + 22 + comment == bytes.count { endings.append(p) }
                }
            }
            guard endings.count == 1, let end = endings.first else { throw NativeIPAArchiveError.invalidArchive }
            guard try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw NativeIPAArchiveError.unsupportedFormat }
            let count = try u16(end + 10)
            guard count > 0, count <= 10000 else { throw NativeIPAArchiveError.resourceLimit }
            guard try u16(end + 8) == count else { throw NativeIPAArchiveError.unsupportedFormat }
            let centralSize = try u32(end + 12); let centralStart = try u32(end + 16)
            let central = try checkedRange(centralStart, centralSize, end: end)
            guard central.upperBound == end else { throw NativeIPAArchiveError.unsupportedFormat }
            var cursor = centralStart; var totalExpanded = 0; var totalNameBytes = 0; var namespaceBytes = 0
            var entries: [Entry] = []; var records: [Range<Int>] = []
            var names = Set<String>(); var namespace: [String: (path: String, directory: Bool)] = [:]
            for _ in 0..<count {
                try Task.checkCancellation()
                _ = try checkedRange(cursor, 46, end: end)
                guard try u32(cursor) == 0x02014b50 else { throw NativeIPAArchiveError.invalidArchive }
                let host = try u16(cursor + 4) >> 8; let version = try u16(cursor + 6)
                let flags = try u16(cursor + 8); let method = try u16(cursor + 10)
                guard host == 0 || host == 3, (version == 10 || version == 20), method != 8 || version == 20, flags & ~0x080e == 0,
                      method == 0 || method == 8, method == 8 || flags & 6 == 0,
                      try u16(cursor + 34) == 0 else { throw NativeIPAArchiveError.unsupportedFormat }
                let crc = try u32(cursor + 16); let compressed = try u32(cursor + 20); let expanded = try u32(cursor + 24)
                guard compressed != 0xffffffff, expanded != 0xffffffff else { throw NativeIPAArchiveError.unsupportedFormat }
                guard expanded <= 128 * 1024 * 1024, expanded <= max(1, compressed) * 250,
                      expanded <= 512 * 1024 * 1024 - totalExpanded else { throw NativeIPAArchiveError.resourceLimit }
                guard method != 0 || compressed == expanded else { throw NativeIPAArchiveError.invalidArchive }
                totalExpanded += expanded
                let nameSize = try u16(cursor + 28); let extraSize = try u16(cursor + 30); let commentSize = try u16(cursor + 32)
                guard nameSize > 0, nameSize <= 1024, extraSize <= 4096,
                      nameSize <= 4 * 1024 * 1024 - totalNameBytes else { throw NativeIPAArchiveError.resourceLimit }
                totalNameBytes += nameSize
                let nameRange = try checkedRange(cursor + 46, nameSize, end: end)
                let extraRange = try checkedRange(nameRange.upperBound, extraSize, end: end)
                let comment = try checkedRange(extraRange.upperBound, commentSize, end: end)
                let nameBytes = Data(bytes[nameRange])
                let directory = nameBytes.last == 47
                let path = try safePath(nameBytes, directory: directory)
                let folded = path.lowercased()
                guard names.insert(folded).inserted else { throw NativeIPAArchiveError.unsafePath }
                let external = try u32(cursor + 38); let mode = (external >> 16) & 0xf000
                if host == 3 {
                    guard mode == (directory ? 0x4000 : 0x8000) else { throw NativeIPAArchiveError.unsupportedFormat }
                } else {
                    guard (external & 0x10 != 0) == directory, mode == 0 else { throw NativeIPAArchiveError.unsupportedFormat }
                }
                guard !directory || (expanded == 0 && compressed == 0 && crc == 0 && method == 0) else { throw NativeIPAArchiveError.invalidArchive }
                try extras(extraRange)
                let offset = try u32(cursor + 42)
                _ = try checkedRange(offset, 30, end: centralStart)
                guard try u32(offset) == 0x04034b50,
                      try u16(offset + 4) == version, try u16(offset + 6) == flags,
                      try u16(offset + 8) == method, try u16(offset + 10) == u16(cursor + 12),
                      try u16(offset + 12) == u16(cursor + 14),
                      try u16(offset + 26) == nameSize else { throw NativeIPAArchiveError.invalidArchive }
                let localName = try checkedRange(offset + 30, nameSize, end: centralStart)
                guard Data(bytes[localName]) == nameBytes else { throw NativeIPAArchiveError.unsafePath }
                let localExtraSize = try u16(offset + 28)
                guard localExtraSize <= 4096 else { throw NativeIPAArchiveError.resourceLimit }
                let localExtra = try checkedRange(localName.upperBound, localExtraSize, end: centralStart)
                try extras(localExtra)
                let payload = try checkedRange(localExtra.upperBound, compressed, end: centralStart)
                var recordEnd = payload.upperBound
                let localCRC = try u32(offset + 14); let localCompressed = try u32(offset + 18); let localExpanded = try u32(offset + 22)
                if flags & 8 == 0 {
                    guard localCRC == crc, localCompressed == compressed, localExpanded == expanded else { throw NativeIPAArchiveError.invalidArchive }
                } else {
                    guard (localCRC == 0 || localCRC == crc), (localCompressed == 0 || localCompressed == compressed),
                          (localExpanded == 0 || localExpanded == expanded) else { throw NativeIPAArchiveError.invalidArchive }
                    _ = try checkedRange(recordEnd, 12, end: centralStart)
                    if try u32(recordEnd) == 0x08074b50 { recordEnd += 4 }
                    _ = try checkedRange(recordEnd, 12, end: centralStart)
                    guard try u32(recordEnd) == crc, try u32(recordEnd + 4) == compressed,
                          try u32(recordEnd + 8) == expanded else { throw NativeIPAArchiveError.invalidArchive }
                    recordEnd += 12
                }
                records.append(offset..<recordEnd)
                entries.append(Entry(path: path, isDirectory: directory, method: method, crc32: UInt32(crc),
                    compressedRange: payload, expandedCount: expanded))
                // Register implicit parent directories too: a file cannot hide a
                // descendant, with or without explicit directory records/order.
                let components = path.split(separator: "/").map(String.init)
                for depth in 1...components.count {
                    let spelling = components.prefix(depth).joined(separator: "/")
                    let prefix = spelling.lowercased()
                    let isDirectory = depth < components.count || directory
                    if let prior = namespace[prefix] {
                        guard prior.directory == isDirectory, prior.path == spelling else { throw NativeIPAArchiveError.unsafePath }
                    } else {
                        guard namespace.count < 20000, spelling.utf8.count <= 8 * 1024 * 1024 - namespaceBytes else { throw NativeIPAArchiveError.resourceLimit }
                        namespaceBytes += spelling.utf8.count
                        namespace[prefix] = (spelling, isDirectory)
                    }
                }
                cursor = comment.upperBound
            }
            guard cursor == end else { throw NativeIPAArchiveError.invalidArchive }
            var covered = 0
            for record in records.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                try Task.checkCancellation()
                guard record.lowerBound == covered else { throw NativeIPAArchiveError.invalidArchive }
                covered = record.upperBound
            }
            guard covered == centralStart else { throw NativeIPAArchiveError.invalidArchive }
            return entries
        }
        try Task.checkCancellation()
        return Self(entries: entries, archiveSHA256: NativeSigningIdentityOwner.hash(data))
    }

    private static func safePath(_ bytes: Data, directory: Bool) throws -> String {
        guard bytes.allSatisfy({ (32...126).contains($0) }), let raw = String(data: bytes, encoding: .ascii),
              !raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains(":"), !raw.contains("//") else { throw NativeIPAArchiveError.unsafePath }
        let path = directory ? String(raw.dropLast()) : raw
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 && $0 != "." && $0 != ".." && !$0.hasSuffix(".") && !$0.hasSuffix(" ") }) else { throw NativeIPAArchiveError.unsafePath }
        return path
    }
}
