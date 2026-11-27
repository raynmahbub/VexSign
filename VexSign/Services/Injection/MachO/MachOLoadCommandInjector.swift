// MARK: - Bounds-checked LC_LOAD_DYLIB planning and mutation
//
// This is an independent Swift implementation for *validating* that a load
// command can be represented in a Mach-O file and for deterministic tests. The
// production signing path keeps using the pinned native engine's injector so
// there is only one mutation mechanism on user apps; this module proves the
// layout is possible before that engine is invoked and re-checks the result
// afterwards. Nothing here executes imported code.

import Foundation

enum MachOLoadCommandError: Error, LocalizedError, Equatable {
    case unsupportedHeader
    case malformedLoadCommands
    case duplicateLoadPath
    case insufficientLoadCommandSpace
    case invalidLoadPath
    case sliceOutOfBounds
    case codeSignatureCommandInvalid

    var errorDescription: String? {
        switch self {
        case .unsupportedHeader: "Only 64-bit little-endian Mach-O files can be prepared here."
        case .malformedLoadCommands: "The binary's load commands are malformed; no bytes were changed."
        case .duplicateLoadPath: "The requested library is already in the binary's load commands."
        case .insufficientLoadCommandSpace: "There is no safe space to add a load command without moving binary data."
        case .invalidLoadPath: "The library reference is empty, too long or contains an illegal character."
        case .sliceOutOfBounds: "A universal binary slice points outside the file."
        case .codeSignatureCommandInvalid: "An existing code-signature command could not be invalidated safely."
        }
    }
}

struct MachOLoadCommandPlan: Equatable, Sendable {
    let sliceOffset: Int
    let insertionOffset: Int
    let command: Data
    let commandCount: UInt32
    let commandBytes: UInt32
    let codeSignatureOffset: Int?
    let architecture: String

    /// Applies the plan to a copy of the slice bytes. Bounds are re-checked at
    /// write time. The previous code-signature command is invalidated only
    /// after the load command has been written successfully.
    func apply(to original: Data) throws -> Data {
        var output = original
        let base = output.startIndex
        guard sliceOffset >= 0, sliceOffset + 32 <= output.count,
              insertionOffset >= sliceOffset + 32,
              insertionOffset + command.count <= output.count else {
            throw MachOLoadCommandError.sliceOutOfBounds
        }
        output.replaceSubrange(
            (base + insertionOffset)..<(base + insertionOffset + command.count),
            with: command
        )
        _write(commandCount, at: sliceOffset + 16, into: &output)
        _write(commandBytes, at: sliceOffset + 20, into: &output)
        if let signature = codeSignatureOffset {
            guard signature >= sliceOffset + 32, signature + 8 <= output.count else {
                throw MachOLoadCommandError.codeSignatureCommandInvalid
            }
            // A zero command is outside ncmds after the count update; the
            // signer appends a fresh LC_CODE_SIGNATURE at the end of commands.
            output.replaceSubrange((base + signature)..<(base + signature + 8), with: Data(repeating: 0, count: 8))
        }
        return output
    }

    private func _write(_ value: UInt32, at offset: Int, into data: inout Data) {
        let base = data.startIndex
        for index in 0..<4 {
            data[base + offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff)
        }
    }
}

enum MachOLoadCommandInjector {
    private static let headerSize = 32
    private static let loadDylib: UInt32 = 0x0c
    private static let codeSignature: UInt32 = 0x1d
    private static let segment64: UInt32 = 0x19
    private static let maximumCommandBytes = 16 * 1024 * 1024
    private static let maximumCommandCount = 65_536

    /// Plans one insertion per device-native slice. Fat offsets and sizes are
    /// preserved because the command is written into slack that already exists
    /// before the first section, so enclosing headers need no adjustment.
    static func plan(in data: Data, loadPath: String) throws -> [MachOLoadCommandPlan] {
        guard let bytes = _commandBytes(for: loadPath) else { throw MachOLoadCommandError.invalidLoadPath }
        let slices = try _sliceRanges(in: data)
        guard !slices.isEmpty else { throw MachOLoadCommandError.unsupportedHeader }
        return try slices.map { slice in
            try _plan(slice: slice, in: data, command: bytes, loadPath: loadPath)
        }
    }

    private static func _commandBytes(for loadPath: String) -> Data? {
        guard !loadPath.isEmpty, loadPath.utf8.count <= 1_024,
              !loadPath.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
            return nil
        }
        let stringBytes = Array(loadPath.utf8) + [0]
        let paddedLength = (24 + stringBytes.count + 7) & ~7
        guard paddedLength <= 2_048 else { return nil }
        var bytes = Data(repeating: 0, count: paddedLength)
        _write(loadDylib, at: 0, into: &bytes)
        _write(UInt32(paddedLength), at: 4, into: &bytes)
        _write(24, at: 8, into: &bytes)
        _write(0x10000, at: 12, into: &bytes) // current_version 1.0
        _write(0x10000, at: 16, into: &bytes) // compatibility_version 1.0
        bytes.replaceSubrange(24..<(24 + stringBytes.count), with: stringBytes)
        return bytes
    }

    private static func _plan(slice: Range<Int>, in data: Data, command: Data, loadPath: String) throws -> MachOLoadCommandPlan {
        let base = data.startIndex
        guard slice.lowerBound >= 0, slice.upperBound <= data.count,
              slice.count >= headerSize,
              _u32(data, at: slice.lowerBound, base: base) == 0xfeedfacf else {
            throw MachOLoadCommandError.unsupportedHeader
        }
        guard let cpu = _u32(data, at: slice.lowerBound + 4, base: base),
              cpu == 0x0100000c else { // arm64 / arm64e only
            throw MachOLoadCommandError.unsupportedHeader
        }
        guard let count = _u32(data, at: slice.lowerBound + 16, base: base),
              let commandBytes = _u32(data, at: slice.lowerBound + 20, base: base),
              count <= maximumCommandCount,
              Int(commandBytes) <= maximumCommandBytes,
              Int(commandBytes) <= slice.count - headerSize,
              Int(count) <= Int(commandBytes) / 8 else {
            throw MachOLoadCommandError.malformedLoadCommands
        }

        let commandsStart = slice.lowerBound + headerSize
        let commandsEnd = commandsStart + Int(commandBytes)
        guard commandsEnd <= slice.upperBound else { throw MachOLoadCommandError.malformedLoadCommands }

        var cursor = commandsStart
        var firstDataOffset = slice.upperBound
        var codeSignatureOffset: Int?
        for _ in 0..<Int(count) {
            guard cursor + 8 <= commandsEnd,
                  let identifier = _u32(data, at: cursor, base: base),
                  let length = _u32(data, at: cursor + 4, base: base),
                  length >= 8, length % 8 == 0,
                  cursor + Int(length) <= commandsEnd else {
                throw MachOLoadCommandError.malformedLoadCommands
            }
            if identifier == codeSignature {
                guard length == 16, codeSignatureOffset == nil else {
                    throw MachOLoadCommandError.codeSignatureCommandInvalid
                }
                codeSignatureOffset = cursor
            } else if identifier == loadDylib, length >= 24,
                      let nameOffset = _u32(data, at: cursor + 8, base: base),
                      nameOffset >= 24, Int(nameOffset) < length {
                let start = cursor + Int(nameOffset)
                let end = cursor + Int(length)
                if _cString(in: data, from: start, to: end, base: base) == loadPath {
                    throw MachOLoadCommandError.duplicateLoadPath
                }
            } else if identifier == segment64 {
                guard length >= 72 else { throw MachOLoadCommandError.malformedLoadCommands }
                guard let fileOffset = _u64(data, at: cursor + 40, base: base),
                      let fileSize = _u64(data, at: cursor + 48, base: base),
                      let sectionCount = _u32(data, at: cursor + 64, base: base),
                      Int(sectionCount) <= (Int(length) - 72) / 80 else {
                    throw MachOLoadCommandError.malformedLoadCommands
                }
                if fileSize > 0, fileOffset >= UInt64(slice.lowerBound), fileOffset < UInt64(firstDataOffset) {
                    firstDataOffset = Int(fileOffset)
                }
                for index in 0..<Int(sectionCount) {
                    let sectionStart = cursor + 72 + index * 80
                    guard let offset = _u32(data, at: sectionStart + 48, base: base) else {
                        throw MachOLoadCommandError.malformedLoadCommands
                    }
                    let sectionOffset = Int(offset)
                    if sectionOffset > 0, sectionOffset < firstDataOffset { firstDataOffset = sectionOffset }
                }
            }
            cursor += Int(length)
        }
        guard commandBytes + UInt32(command.count) <= maximumCommandBytes else {
            throw MachOLoadCommandError.malformedLoadCommands
        }
        guard commandsEnd + command.count <= firstDataOffset else {
            throw MachOLoadCommandError.insufficientLoadCommandSpace
        }
        let removedSignature = codeSignatureOffset == nil ? 0 : 1
        let newCount = count - UInt32(removedSignature) + 1
        guard newCount <= maximumCommandCount else { throw MachOLoadCommandError.malformedLoadCommands }

        return MachOLoadCommandPlan(
            sliceOffset: slice.lowerBound,
            insertionOffset: commandsEnd,
            command: command,
            commandCount: newCount,
            commandBytes: commandBytes + UInt32(command.count),
            codeSignatureOffset: codeSignatureOffset,
            architecture: "arm64"
        )
    }

    private static func _sliceRanges(in data: Data) throws -> [Range<Int>] {
        guard data.count >= 4 else { throw MachOLoadCommandError.unsupportedHeader }
        let base = data.startIndex
        let magic = _u32(data, at: 0, base: base) ?? 0
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let entrySize = magic == 0xcafebabe ? 20 : 32
            guard let count = _u32(data, at: 4, base: base), count <= 64,
                  8 + Int(count) * entrySize <= data.count else {
                throw MachOLoadCommandError.sliceOutOfBounds
            }
            var ranges: [Range<Int>] = []
            for index in 0..<Int(count) {
                let entry = 8 + index * entrySize
                let start: UInt64?
                let size: UInt64?
                if entrySize == 20 {
                    start = _u32(data, at: entry + 8, base: base).map(UInt64.init)
                    size = _u32(data, at: entry + 12, base: base).map(UInt64.init)
                } else {
                    start = _u64(data, at: entry + 8, base: base)
                    size = _u64(data, at: entry + 16, base: base)
                }
                guard let start, let size, size >= UInt64(headerSize),
                      start <= UInt64(data.count), size <= UInt64(data.count) - start else {
                    throw MachOLoadCommandError.sliceOutOfBounds
                }
                ranges.append(Int(start)..<Int(start + size))
            }
            return ranges
        }
        if magic == 0xfeedfacf { return [0..<data.count] }
        throw MachOLoadCommandError.unsupportedHeader
    }

    private static func _u32(_ data: Data, at offset: Int, base: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[base + offset])
            | (UInt32(data[base + offset + 1]) << 8)
            | (UInt32(data[base + offset + 2]) << 16)
            | (UInt32(data[base + offset + 3]) << 24)
    }

    private static func _u64(_ data: Data, at offset: Int, base: Int) -> UInt64? {
        guard let low = _u32(data, at: offset, base: base),
              let high = _u32(data, at: offset + 4, base: base) else { return nil }
        return UInt64(low) | (UInt64(high) << 32)
    }

    private static func _cString(in data: Data, from start: Int, to end: Int, base: Int) -> String? {
        guard start >= 0, end <= data.count, start < end else { return nil }
        var cursor = start
        while cursor < end, data[base + cursor] != 0 { cursor += 1 }
        guard cursor < end else { return nil }
        return String(bytes: data[(base + start)..<(base + cursor)], encoding: .utf8)
    }

    private static func _write(_ value: UInt32, at offset: Int, into data: inout Data) {
        let base = data.startIndex
        for index in 0..<4 {
            data[base + offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff)
        }
    }
}
