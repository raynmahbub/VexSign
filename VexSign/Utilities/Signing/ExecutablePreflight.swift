import Foundation

/// Read-only, bounded Mach-O inspection. Unknown never means compatible.
/// This is not a signature/CMS verifier and does not replace native capability gates.
enum ExecutablePreflight {
    struct Evidence: Equatable {
        let isArm64: Bool
        let encrypted: Bool
        let platform: UInt32?
        let minimumOS: UInt32?
    }

    /// Compatibility entry point for UI callers interested in the device arm64 slice.
    static func inspect(_ data: Data) -> Evidence? {
        guard let slices = inspectSlices(data) else { return nil }
        return slices.first(where: { $0.isArm64 }) ?? slices.first
    }

    /// Every fat slice is bounded to its own range. A command cannot borrow bytes from a sibling.
    static func inspectSlices(_ data: Data) -> [Evidence]? {
        func word(_ offset: Int) -> UInt32? { MachOReader.u32(data, at: offset, bigEndian: true) }
        func wide(_ offset: Int) -> UInt64? {
            guard let high = word(offset), let low = word(offset + 4) else { return nil }
            return (UInt64(high) << 32) | UInt64(low)
        }
        guard let magic = word(0) else { return nil }
        if magic != MachOReader.fat && magic != MachOReader.fat64 {
            return inspectSlice(data, range: 0..<data.count).map { [$0] }
        }
        let entrySize = magic == MachOReader.fat ? 20 : 32
        guard let count = word(4), count > 0, count <= 64,
              Int(count) <= max(0, data.count - 8) / entrySize else { return nil }
        let tableEnd = 8 + Int(count) * entrySize
        var ranges: [(range: Range<Int>, cpu: UInt32)] = []
        for index in 0..<Int(count) {
            let entry = 8 + index * entrySize
            guard let cpu = word(entry) else { return nil }
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
            ranges.append((Int(start)..<Int(start + size), cpu))
        }
        let ordered = ranges.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for index in 1..<ordered.count {
            guard ordered[index - 1].range.upperBound <= ordered[index].range.lowerBound else { return nil }
        }
        var result: [Evidence] = []
        for slice in ranges {
            guard let evidence = inspectSlice(data, range: slice.range, expectedCPU: slice.cpu) else { return nil }
            result.append(evidence)
        }
        return result
    }

    private static func inspectSlice(_ data: Data, range: Range<Int>, expectedCPU: UInt32? = nil) -> Evidence? {
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
        guard range.count >= headerSize, let cpu = word(4), expectedCPU == nil || cpu == expectedCPU,
              let count = word(16), let size = word(20), count <= 65536, size <= 16 * 1024 * 1024,
              Int(size) <= range.count - headerSize, count <= size / 8 else { return nil }
        let end = headerSize + Int(size)
        var offset = headerSize
        var encrypted = false
        var platform: UInt32?
        var minimum: UInt32?
        for _ in 0..<count {
            guard offset <= end - 8, let command = word(offset), let length = word(offset + 4),
                  length >= 8, length % 4 == 0, Int(length) <= end - offset else { return nil }
            switch command {
            case 0x21, 0x2c:
                guard length >= (command == 0x2c ? 24 : 20), let cryptID = word(offset + 16) else { return nil }
                encrypted = encrypted || cryptID != 0
            case 0x32:
                guard length >= 24, platform == nil, let p = word(offset + 8),
                      let m = word(offset + 12), let tools = word(offset + 20),
                      tools <= (length - 24) / 8, length == 24 + tools * 8 else { return nil }
                platform = p
                minimum = m
            case 0x25:
                guard length >= 16, platform == nil else { return nil }
                platform = 2
                minimum = word(offset + 8)
            default: break
            }
            offset += Int(length)
        }
        guard offset == end else { return nil }
        return Evidence(isArm64: cpu == MachOReader.cpuTypeArm64, encrypted: encrypted,
                        platform: platform, minimumOS: minimum)
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
