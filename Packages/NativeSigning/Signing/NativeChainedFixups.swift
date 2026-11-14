import Foundation

/// Restricted DYLD_CHAINED_PTR_64_OFFSET / DYLD_CHAINED_IMPORT dialect. No
/// authenticated pointers, addends, weak/special imports, compressed symbols or
/// multi-start pages. Reads disk metadata only, never patches or resolves pointers.
struct NativeChainedFixups {
    static func validate(_ payload: Data, image: Data, segments: [NativeDyldSegment],
                         dependencyCount: Int, signatureOffset: Int) throws {
        try Task.checkCancellation()
        guard (28...4 * 1024 * 1024).contains(payload.count), image.count <= 64 * 1024 * 1024,
              segments.count <= 16, (0...253).contains(dependencyCount),
              signatureOffset >= 0, signatureOffset <= image.count,
              segments.allSatisfy({ $0.file.lowerBound >= 0 && $0.file.upperBound <= signatureOffset && $0.address <= UInt64.max - $0.vmSize }),
              let base = segments.first(where: { $0.file.lowerBound == 0 && !$0.file.isEmpty && $0.executable })?.address else { throw NativeSignedOutputError.unsupportedClaims }
        let bytes = Array(payload)
        func integer(_ p: Int, _ count: Int = 4) throws -> UInt64 {
            guard p >= 0, p <= bytes.count - count else { throw NativeSignedOutputError.unsupportedClaims }
            var value: UInt64 = 0
            for i in 0..<count { value |= UInt64(bytes[p + i]) << (i * 8) }
            return value
        }
        var coverage = [Bool](repeating: false, count: bytes.count)
        func mark(_ start: Int, _ size: Int) throws {
            guard start >= 0, size >= 0, start <= bytes.count, size <= bytes.count - start else { throw NativeSignedOutputError.unsupportedClaims }
            for p in start..<(start + size) {
                if p & 65535 == 0 { try Task.checkCancellation() }
                guard !coverage[p] else { throw NativeSignedOutputError.unsupportedClaims }
                coverage[p] = true
            }
        }
        guard try integer(0) == 0, try integer(20) == 1, try integer(24) == 0 else { throw NativeSignedOutputError.unsupportedClaims }
        let starts = Int(try integer(4)); let imports = Int(try integer(8)); let symbols = Int(try integer(12))
        let importCount = Int(try integer(16))
        guard starts >= 28, starts % 4 == 0, imports >= 28, imports % 4 == 0,
              symbols >= 28, symbols <= bytes.count, importCount <= 65536,
              importCount <= (bytes.count - min(imports, bytes.count)) / 4,
              try integer(starts) == UInt64(segments.count) else { throw NativeSignedOutputError.unsupportedClaims }
        try mark(0, 28); try mark(starts, 4 + segments.count * 4); try mark(imports, importCount * 4)
        try mark(symbols, bytes.count - symbols)
        // Canonical uncompressed NUL-delimited symbol pool; suffix-offset aliases
        // and unreferenced names are outside this first dialect.
        var names = Set<Int>(); var referenced = Set<Int>(); var cursor = symbols
        while cursor < bytes.count {
            try Task.checkCancellation()
            if bytes.count - cursor <= 7, bytes[cursor...].allSatisfy({ $0 == 0 }) { break }
            let start = cursor
            while cursor < bytes.count, bytes[cursor] != 0 {
                guard cursor - start < 1024, (33...126).contains(bytes[cursor]) else { throw NativeSignedOutputError.unsupportedClaims }
                cursor += 1
            }
            guard cursor > start, cursor < bytes.count, names.count < importCount else { throw NativeSignedOutputError.unsupportedClaims }
            names.insert(start - symbols); cursor += 1
        }
        for i in 0..<importCount {
            if i & 255 == 0 { try Task.checkCancellation() }
            let entry = try integer(imports + i * 4)
            let ordinal = Int(entry & 255); let name = Int(entry >> 9)
            guard ordinal > 0, ordinal <= min(dependencyCount, 240), entry & 256 == 0, names.contains(name) else { throw NativeSignedOutputError.unsupportedClaims }
            referenced.insert(name)
        }
        guard names == referenced else { throw NativeSignedOutputError.unsupportedClaims }
        var targets = Set<Int>()
        for index in segments.indices {
            try Task.checkCancellation()
            let relative = Int(try integer(starts + 4 + index * 4))
            if relative == 0 { continue }
            guard relative <= bytes.count - starts else { throw NativeSignedOutputError.unsupportedClaims }
            let p = starts + relative
            let size = Int(try integer(p)); let pageSize = Int(try integer(p + 4, 2))
            let segment = segments[index]; let pageCount = Int(try integer(p + 20, 2))
            guard [4096, 16384].contains(pageSize), try integer(p + 6, 2) == 6,
                  segment.address >= base, try integer(p + 8, 8) == segment.address - base,
                  try integer(p + 16) == 0, size == 22 + pageCount * 2,
                  UInt64(pageCount) <= segment.vmSize / UInt64(pageSize) + (segment.vmSize % UInt64(pageSize) == 0 ? 0 : 1),
                  segment.writable, !segment.executable else { throw NativeSignedOutputError.unsupportedClaims }
            try mark(p, size)
            for page in 0..<pageCount {
                if page & 255 == 0 { try Task.checkCancellation() }
                let start = Int(try integer(p + 22 + page * 2, 2))
                if start == 0xffff { continue }
                guard start & 0x8000 == 0, start % 8 == 0, start <= pageSize - 8 else { throw NativeSignedOutputError.unsupportedClaims }
                let pageStart = page * pageSize
                var offset = pageStart + start
                while true {
                    try Task.checkCancellation()
                    guard offset <= segment.file.count, segment.file.count - offset >= 8,
                          offset <= pageStart + pageSize - 8, targets.count < 262144 else { throw NativeSignedOutputError.unsupportedClaims }
                    let file = segment.file.lowerBound + offset
                    guard targets.insert(file).inserted else { throw NativeSignedOutputError.unsupportedClaims }
                    var pointer: UInt64 = 0
                    for i in 0..<8 { pointer |= UInt64(image[image.startIndex + file + i]) << (8 * i) }
                    let next = Int((pointer >> 51) & 0xfff)
                    if pointer >> 63 == 1 {
                        guard (pointer >> 24) & 0x7ffffff == 0, Int(pointer & 0xffffff) < importCount else { throw NativeSignedOutputError.unsupportedClaims }
                    } else {
                        // No high8 tagging or reserved bits in this narrow offset dialect.
                        guard (pointer >> 36) & 0x7fff == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                        let relativeTarget = pointer & 0xfffffffff
                        guard relativeTarget <= UInt64.max - base else { throw NativeSignedOutputError.unsupportedClaims }
                        let address = base + relativeTarget
                        guard segments.contains(where: { !$0.file.isEmpty && address >= $0.address && address - $0.address < min($0.vmSize, UInt64($0.file.count)) }) else { throw NativeSignedOutputError.unsupportedClaims }
                    }
                    if next == 0 { break }
                    guard next % 2 == 0, next * 4 <= pageStart + pageSize - 8 - offset else { throw NativeSignedOutputError.unsupportedClaims }
                    offset += next * 4
                }
            }
        }
        // Only inert zero alignment gaps may remain, never hidden metadata.
        var gap = 0
        for p in bytes.indices {
            if p & 65535 == 0 { try Task.checkCancellation() }
            if coverage[p] { gap = 0 }
            else { gap += 1; guard gap <= 7, bytes[p] == 0 else { throw NativeSignedOutputError.unsupportedClaims } }
        }
    }
}
