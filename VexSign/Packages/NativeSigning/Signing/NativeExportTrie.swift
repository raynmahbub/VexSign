import Foundation

/// Bounded regular/weak regular export trie subset. This reads file metadata only,
/// never resolves a symbol or executes an exported function. Reexports, absolute/
/// TLS exports, resolver stubs and shared/cyclic node graphs are unsupported.
struct NativeExportTrie {
    private struct Reader {
        let bytes: [UInt8]
        var offset: Int
        let end: Int
        mutating func byte() throws -> UInt8 {
            guard offset < end else { throw NativeSignedOutputError.unsupportedClaims }
            defer { offset += 1 }; return bytes[offset]
        }
        mutating func uleb() throws -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<10 {
                let b = try byte(); let value = b & 127
                guard i < 9 || value <= 1 else { throw NativeSignedOutputError.unsupportedClaims }
                result |= UInt64(value) << (i * 7)
                if b & 128 == 0 {
                    guard i == 0 || value != 0 else { throw NativeSignedOutputError.unsupportedClaims }
                    return result
                }
            }
            throw NativeSignedOutputError.unsupportedClaims
        }
        mutating func edge() throws -> String {
            var result: [UInt8] = []
            while true {
                let b = try byte()
                if b == 0 {
                    guard !result.isEmpty, let name = String(bytes: result, encoding: .ascii) else { throw NativeSignedOutputError.unsupportedClaims }
                    return name
                }
                guard result.count < 1024, (33...126).contains(b) else { throw NativeSignedOutputError.unsupportedClaims }
                result.append(b)
            }
        }
    }

    static func validate(_ data: Data, segments: [NativeDyldSegment], signatureOffset: Int) throws {
        try Task.checkCancellation()
        guard data.count <= 4 * 1024 * 1024, segments.count <= 16, signatureOffset >= 0,
              segments.allSatisfy({ $0.file.lowerBound >= 0 && $0.file.upperBound <= signatureOffset && $0.address <= UInt64.max - $0.vmSize }),
              let base = segments.first(where: { $0.file.lowerBound == 0 && !$0.file.isEmpty && $0.executable })?.address else {
            throw NativeSignedOutputError.unsupportedClaims
        }
        if data.isEmpty { return }
        let bytes = Array(data)
        var stack: [(offset: Int, prefix: String, depth: Int)] = [(0, "", 0)]
        var seen = Set<Int>(); var symbols = Set<String>(); var ranges: [Range<Int>] = []
        var nameBytes = 0
        while let work = stack.popLast() {
            try Task.checkCancellation()
            guard work.offset < bytes.count, seen.count < 16384, seen.insert(work.offset).inserted,
                  work.depth <= 128, work.prefix.utf8.count <= 1024 else { throw NativeSignedOutputError.unsupportedClaims }
            var node = Reader(bytes: bytes, offset: work.offset, end: bytes.count)
            let terminalSize = try node.uleb()
            guard terminalSize <= UInt64(bytes.count - node.offset) else { throw NativeSignedOutputError.unsupportedClaims }
            let terminalEnd = node.offset + Int(terminalSize)
            if terminalSize > 0 {
                guard !work.prefix.isEmpty, symbols.insert(work.prefix).inserted else { throw NativeSignedOutputError.unsupportedClaims }
                var terminal = Reader(bytes: bytes, offset: node.offset, end: terminalEnd)
                let flags = try terminal.uleb()
                guard flags == 0 || flags == 4 else { throw NativeSignedOutputError.unsupportedClaims }
                let relative = try terminal.uleb()
                guard terminal.offset == terminalEnd, relative <= UInt64.max - base else { throw NativeSignedOutputError.unsupportedClaims }
                let address = base + relative
                guard segments.contains(where: {
                    !$0.file.isEmpty && address >= $0.address && address - $0.address < min($0.vmSize, UInt64($0.file.count))
                }) else { throw NativeSignedOutputError.unsupportedClaims }
            }
            node.offset = terminalEnd
            let children = Int(try node.byte())
            guard stack.count + children <= 16384 else { throw NativeSignedOutputError.unsupportedClaims }
            var firstBytes = Set<UInt8>()
            for _ in 0..<children {
                let edge = try node.edge()
                guard let first = edge.utf8.first, firstBytes.insert(first).inserted else { throw NativeSignedOutputError.unsupportedClaims }
                let offset = try node.uleb()
                guard offset < UInt64(bytes.count) else { throw NativeSignedOutputError.unsupportedClaims }
                let prefix = work.prefix + edge
                nameBytes += prefix.utf8.count
                guard nameBytes <= 1024 * 1024 else { throw NativeSignedOutputError.unsupportedClaims }
                stack.append((Int(offset), prefix, work.depth + 1))
            }
            let range = work.offset..<node.offset
            ranges.append(range)
        }
        // Every reachable node occupies one disjoint range. Unreachable/hidden
        // metadata, alternate interpretations and interior gaps are rejected.
        var end = 0
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound == end else { throw NativeSignedOutputError.unsupportedClaims }
            end = range.upperBound
        }
        guard bytes.count - end <= 7, bytes[end...].allSatisfy({ $0 == 0 }) else { throw NativeSignedOutputError.unsupportedClaims }
    }
}
