import Foundation

/// Read-only, bounded Mach-O inspection. Unknown never means compatible.
/// This is not a signature/CMS verifier and does not replace native capability gates.
enum ExecutablePreflight {
    struct Evidence: Equatable {
        let isArm64: Bool
        let cpuType: UInt32
        let encrypted: Bool
        let platform: UInt32?
        let minimumOS: UInt32?
        let fileType: UInt32
    }

    /// Compatibility entry point for UI callers interested in the device arm64 slice.
    static func inspect(_ data: Data) -> Evidence? {
        guard let slices = inspectSlices(data) else { return nil }
        return slices.first(where: { $0.isArm64 }) ?? slices.first
    }

    struct Image {
        let range: Range<Int>
        let evidence: Evidence
    }

    /// Every fat slice is bounded to its own range. A command cannot borrow bytes from a sibling.
    static func inspectSlices(_ data: Data) -> [Evidence]? { inspectImages(data)?.map(\.evidence) }

    static func inspectImages(_ data: Data) -> [Image]? {
        let data = Data(data)
        guard let magic = MachOReader.u32(data, at: 0, bigEndian: true) else { return nil }
        let big: Bool, entrySize: Int
        switch magic {
        case MachOReader.fat: big = true; entrySize = 20
        case MachOReader.fat64: big = true; entrySize = 32
        case 0xbebafeca: big = false; entrySize = 20
        case 0xbfbafeca: big = false; entrySize = 32
        default:
            return inspectSlice(data, range: 0..<data.count).map { [Image(range: 0..<data.count, evidence: $0)] }
        }
        func word(_ offset: Int) -> UInt32? { MachOReader.u32(data, at: offset, bigEndian: big) }
        func wide(_ offset: Int) -> UInt64? {
            guard let first = word(offset), let second = word(offset + 4) else { return nil }
            return big ? UInt64(first) << 32 | UInt64(second) : UInt64(second) << 32 | UInt64(first)
        }
        guard let count = word(4), count > 0, count <= 64,
              Int(count) <= max(0, data.count - 8) / entrySize else { return nil }
        let tableEnd = 8 + Int(count) * entrySize
        var ranges: [(range: Range<Int>, cpu: UInt32, subtype: UInt32)] = []
        for index in 0..<Int(count) {
            let entry = 8 + index * entrySize
            guard let cpu = word(entry), let subtype = word(entry + 4) else { return nil }
            let start: UInt64?
            let size: UInt64?
            let alignment: UInt32?
            if entrySize == 20 {
                start = word(entry + 8).map(UInt64.init)
                size = word(entry + 12).map(UInt64.init)
                alignment = word(entry + 16)
            } else {
                start = wide(entry + 8)
                size = wide(entry + 16)
                alignment = word(entry + 24)
                guard word(entry + 28) == 0 else { return nil }
            }
            guard let start, let size, let alignment, alignment <= 30,
                  start >= UInt64(tableEnd), start <= UInt64(data.count),
                  size >= 28, size <= UInt64(data.count) - start,
                  start % (UInt64(1) << alignment) == 0 else { return nil }
            ranges.append((Int(start)..<Int(start + size), cpu, subtype))
        }
        let ordered = ranges.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for index in 1..<ordered.count {
            guard ordered[index - 1].range.upperBound <= ordered[index].range.lowerBound else { return nil }
        }
        var result: [Image] = []
        for slice in ranges {
            guard let evidence = inspectSlice(data, range: slice.range, expectedCPU: slice.cpu, expectedSubtype: slice.subtype) else { return nil }
            result.append(Image(range: slice.range, evidence: evidence))
        }
        return result
    }

    private static func inspectSlice(_ data: Data, range: Range<Int>, expectedCPU: UInt32? = nil, expectedSubtype: UInt32? = nil) -> Evidence? {
        guard range.lowerBound >= 0, range.upperBound <= data.count, range.count >= 28,
              let magic = MachOReader.u32(data, at: range.lowerBound, bigEndian: false) else { return nil }
        let bigEndian: Bool
        let headerSize: Int
        switch magic {
        case 0xfeedfacf: bigEndian = false; headerSize = 32
        case 0xcffaedfe: bigEndian = true; headerSize = 32
        case 0xfeedface: bigEndian = false; headerSize = 28
        case 0xcefaedfe: bigEndian = true; headerSize = 28
        default: return nil
        }
        func word(_ relative: Int) -> UInt32? {
            guard relative >= 0, relative <= range.count - 4 else { return nil }
            return MachOReader.u32(data, at: range.lowerBound + relative, bigEndian: bigEndian)
        }
        guard range.count >= headerSize, let cpu = word(4), let subtype = word(8), let fileType = word(12),
              expectedCPU == nil || cpu == expectedCPU, expectedSubtype == nil || subtype == expectedSubtype,
              let count = word(16), let size = word(20), count <= 65536, size <= 16 * 1024 * 1024,
              Int(size) <= range.count - headerSize, count <= size / 8 else { return nil }
        func wide(_ offset: Int) -> UInt64? {
            guard let first = word(offset), let second = word(offset + 4) else { return nil }
            return bigEndian ? UInt64(first) << 32 | UInt64(second) : UInt64(second) << 32 | UInt64(first)
        }
        func fileRange(_ start: UInt64?, _ length: UInt64?) -> Bool {
            guard let start, let length else { return false }
            return start <= UInt64(range.count) && length <= UInt64(range.count) - start
        }
        func name(_ offset: Int) -> String? {
            let start = range.lowerBound + offset
            guard offset >= 0, offset <= range.count - 16 else { return nil }
            // Mach-O name fields are fixed-width char[16], not C strings. A
            // complete 16-byte name is legal and must not borrow a terminator
            // from the following struct field.
            let end = data[start..<(start + 16)].firstIndex(of: 0) ?? (start + 16)
            return String(data: data[start..<end], encoding: .utf8)
        }
        func commandString(_ offset: Int, _ minimum: Int, _ length: Int) -> Bool {
            guard let value = word(offset + 8), Int(value) >= minimum, Int(value) < length else { return false }
            let start = range.lowerBound + offset + Int(value), end = range.lowerBound + offset + length
            return data[start..<end].contains(0)
        }
        let end = headerSize + Int(size)
        var offset = headerSize
        var encrypted = false
        var platform: UInt32?
        var minimum: UInt32?
        for _ in 0..<count {
            guard offset <= end - 8, let command = word(offset), let length = word(offset + 4),
                  length >= 8, length % 4 == 0, Int(length) <= end - offset else { return nil }
            switch command {
            case 0x01, 0x19: // Native segment/section readers must never see partial structs.
                let is64 = command == 0x19, fixed = is64 ? 72 : 56, sectionSize = is64 ? 80 : 68
                guard Int(length) >= fixed, let sections = word(offset + (is64 ? 64 : 48)), sections <= 4096,
                      Int(sections) <= (Int(length) - fixed) / sectionSize,
                      let segment = name(offset + 8) else { return nil }
                let fileOffset = is64 ? wide(offset + 40) : word(offset + 32).map(UInt64.init)
                let fileSize = is64 ? wide(offset + 48) : word(offset + 36).map(UInt64.init)
                guard fileRange(fileOffset, fileSize) else { return nil }
                for index in 0..<Int(sections) {
                    let section = offset + fixed + index * sectionSize
                    guard name(section) != nil, name(section + 16) == segment,
                          let flags = word(section + (is64 ? 64 : 56)),
                          let fileStart = word(section + (is64 ? 48 : 40)) else { return nil }
                    let byteCount = is64 ? wide(section + 40) : word(section + 36).map(UInt64.init)
                    if ![UInt32(1), 0x0c, 0x12].contains(flags & 0xff), !fileRange(UInt64(fileStart), byteCount) { return nil }
                }
            case 0x0c, 0x0d, 0x80000018, 0x8000001f, 0x80000023, 0x20:
                guard length >= 24, commandString(offset, 24, Int(length)) else { return nil }
            case 0x8000001c, 0x0e, 0x0f, 0x27:
                guard length >= 12, commandString(offset, 12, Int(length)) else { return nil }
            case 0x1d, 0x1e, 0x26, 0x29, 0x2b, 0x2e, 0x80000033, 0x80000034:
                guard length == 16, fileRange(word(offset + 8).map(UInt64.init), word(offset + 12).map(UInt64.init)) else { return nil }
            case 0x02:
                guard length == 24, let symbols = word(offset + 12),
                      fileRange(word(offset + 8).map(UInt64.init), UInt64(symbols) * UInt64(headerSize == 32 ? 16 : 12)),
                      fileRange(word(offset + 16).map(UInt64.init), word(offset + 20).map(UInt64.init)) else { return nil }
            case 0x22, 0x80000022:
                guard length == 48 else { return nil }
                for pair in 0..<5 {
                    guard fileRange(word(offset + 8 + pair * 8).map(UInt64.init), word(offset + 12 + pair * 8).map(UInt64.init)) else { return nil }
                }
            case 0x21, 0x2c:
                guard length == (command == 0x2c ? 24 : 20), let cryptID = word(offset + 16),
                      fileRange(word(offset + 8).map(UInt64.init), word(offset + 12).map(UInt64.init)) else { return nil }
                encrypted = encrypted || cryptID != 0
            case 0x80000028:
                guard length == 24, let entry = wide(offset + 8), entry < UInt64(range.count) else { return nil }
            case 0x32:
                guard length >= 24, platform == nil, let p = word(offset + 8),
                      let m = word(offset + 12), let tools = word(offset + 20),
                      tools <= (length - 24) / 8, length == 24 + tools * 8 else { return nil }
                platform = p
                minimum = m
            case 0x24, 0x25, 0x2f, 0x30:
                guard length == 16, platform == nil else { return nil }
                platform = [UInt32(0x24): UInt32(1), 0x25: 2, 0x2f: 3, 0x30: 4][command]
                minimum = word(offset + 8)
            default: break
            }
            offset += Int(length)
        }
        guard offset == end else { return nil }
        return Evidence(isArm64: cpu == MachOReader.cpuTypeArm64, cpuType: cpu, encrypted: encrypted,
                        platform: platform, minimumOS: minimum, fileType: fileType)
    }

    static func packedVersion(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { UInt32($0) }
        guard values.count == parts.count, values[0] <= 65535,
              values.dropFirst().allSatisfy({ $0 <= 255 }) else { return nil }
        return (values[0] << 16) | ((values.count > 1 ? values[1] : 0) << 8) | (values.count > 2 ? values[2] : 0)
    }
}
