import Foundation

/// Context comes from independently validated load commands; no process memory,
/// dylib loading or pointer writes occur here. Pointer checks read on-disk bytes.
struct NativeDyldSegment: Sendable {
    let file: Range<Int>
    let address: UInt64
    let vmSize: UInt64
    let writable: Bool
    let executable: Bool
}

/// Supported legacy dialect: pointer rebases, positive system-library ordinal
/// regular/lazy binds, ASCII symbols, zero addends. No threaded/authenticated
/// fixups, weak-binding streams, special ordinals or non-pointer writes.
struct NativeDyldBytecode {
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var finished: Bool { offset == bytes.count }
        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw NativeSignedOutputError.unsupportedClaims }
            defer { offset += 1 }; return bytes[offset]
        }
        mutating func uleb() throws -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<10 {
                let value = try byte(); let payload = value & 0x7f
                guard i < 9 || payload <= 1 else { throw NativeSignedOutputError.unsupportedClaims }
                result |= UInt64(payload) << (i * 7)
                if value & 0x80 == 0 {
                    guard i == 0 || payload != 0 else { throw NativeSignedOutputError.unsupportedClaims }
                    return result
                }
            }
            throw NativeSignedOutputError.unsupportedClaims
        }
        mutating func symbol() throws {
            var count = 0
            while true {
                let value = try byte()
                if value == 0 { guard count > 0 else { throw NativeSignedOutputError.unsupportedClaims }; return }
                count += 1
                guard count <= 1024, (33...126).contains(value) else { throw NativeSignedOutputError.unsupportedClaims }
            }
        }
        var isPadding: Bool { bytes.count - offset <= 7 && bytes[offset...].allSatisfy { $0 == 0 } }
    }

    static func validate(rebase: Data, bind: Data, lazyBind: Data, image: Data,
                         segments: [NativeDyldSegment], dependencyCount: Int,
                         signatureOffset: Int) throws {
        try Task.checkCancellation()
        guard image.count <= 64 * 1024 * 1024, segments.count <= 16,
              (0...253).contains(dependencyCount), signatureOffset >= 0, signatureOffset <= image.count,
              rebase.count <= 4 * 1024 * 1024, bind.count <= 4 * 1024 * 1024,
              lazyBind.count <= 4 * 1024 * 1024,
              segments.allSatisfy({ $0.file.lowerBound >= 0 && $0.file.upperBound <= signatureOffset && $0.address <= UInt64.max - $0.vmSize }) else {
            throw NativeSignedOutputError.unsupportedClaims
        }
        var rebaseTargets = Set<Int>(); var bindTargets = Set<Int>()
        func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
            guard b <= UInt64.max - a else { throw NativeSignedOutputError.unsupportedClaims }
            return a + b
        }
        func target(segment: Int?, offset: UInt64, kind: Int) throws -> Int {
            guard let segment, segment < segments.count else { throw NativeSignedOutputError.unsupportedClaims }
            let selected = segments[segment]
            guard selected.writable, !selected.executable, offset % 8 == 0,
                  offset <= UInt64(selected.file.count), UInt64(selected.file.count) - offset >= 8 else { throw NativeSignedOutputError.unsupportedClaims }
            let file = selected.file.lowerBound + Int(offset)
            guard rebaseTargets.count + bindTargets.count < 262144 else { throw NativeSignedOutputError.unsupportedClaims }
            if kind == 0 {
                guard rebaseTargets.insert(file).inserted else { throw NativeSignedOutputError.unsupportedClaims }
            } else {
                guard bindTargets.insert(file).inserted, kind == 2 || !rebaseTargets.contains(file) else { throw NativeSignedOutputError.unsupportedClaims }
            }
            return file
        }
        func pointer(_ p: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(image[image.startIndex + p + i]) << (i * 8) }
            return value
        }
        if !rebase.isEmpty {
            var reader = Reader(bytes: Array(rebase)); var segment: Int?; var offset: UInt64 = 0; var typed = false
            var done = false
            while !reader.finished {
                try Task.checkCancellation()
                let byte = try reader.byte(); let opcode = byte & 0xf0; let immediate = byte & 0x0f
                func perform(_ count: UInt64, skip: UInt64) throws {
                    guard typed, count > 0, count <= 262144 else { throw NativeSignedOutputError.unsupportedClaims }
                    for _ in 0..<Int(count) {
                        try Task.checkCancellation()
                        let p = try target(segment: segment, offset: offset, kind: 0)
                        let value = pointer(p)
                        guard value != 0, segments.contains(where: { value >= $0.address && value - $0.address < min($0.vmSize, UInt64($0.file.count)) && !$0.file.isEmpty }) else {
                            throw NativeSignedOutputError.unsupportedClaims
                        }
                        offset = try add(offset, add(8, skip))
                    }
                }
                switch opcode {
                case 0x00:
                    guard immediate == 0, reader.isPadding else { throw NativeSignedOutputError.unsupportedClaims }
                    done = true
                case 0x10:
                    guard immediate == 1 else { throw NativeSignedOutputError.unsupportedClaims }; typed = true
                case 0x20:
                    guard Int(immediate) < segments.count else { throw NativeSignedOutputError.unsupportedClaims }
                    segment = Int(immediate); offset = try reader.uleb()
                case 0x30:
                    guard immediate == 0, segment != nil else { throw NativeSignedOutputError.unsupportedClaims }
                    offset = try add(offset, reader.uleb())
                case 0x40:
                    guard segment != nil else { throw NativeSignedOutputError.unsupportedClaims }
                    offset = try add(offset, UInt64(immediate) * 8)
                case 0x50: try perform(UInt64(immediate), skip: 0)
                case 0x60:
                    guard immediate == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                    try perform(reader.uleb(), skip: 0)
                case 0x70:
                    guard immediate == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                    try perform(1, skip: reader.uleb())
                case 0x80:
                    guard immediate == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                    let count = try reader.uleb(); let skip = try reader.uleb(); try perform(count, skip: skip)
                default: throw NativeSignedOutputError.unsupportedClaims
                }
                if done { break }
            }
            guard done else { throw NativeSignedOutputError.unsupportedClaims }
        }
        func bindings(_ data: Data, lazy: Bool) throws {
            if data.isEmpty { return }
            var reader = Reader(bytes: Array(data)); var segment: Int?; var offset: UInt64 = 0
            var ordinal = 0; var symbol = false; var emitted = false; var done = false
            while !reader.finished {
                try Task.checkCancellation()
                let byte = try reader.byte(); let opcode = byte & 0xf0; let immediate = byte & 0x0f
                func perform(_ count: UInt64, skip: UInt64) throws {
                    guard ordinal > 0, ordinal <= dependencyCount, symbol, count > 0, count <= 262144 else { throw NativeSignedOutputError.unsupportedClaims }
                    for _ in 0..<Int(count) {
                        try Task.checkCancellation()
                        let p = try target(segment: segment, offset: offset, kind: lazy ? 2 : 1)
                        // Unbound regular pointers must be zero. Lazy pointers may
                        // contain an in-image helper address, validated below.
                        let value = pointer(p)
                        guard value == 0 || (lazy && value % 4 == 0 && segments.contains(where: { $0.executable && value >= $0.address && value - $0.address < UInt64($0.file.count) })) else {
                            throw NativeSignedOutputError.unsupportedClaims
                        }
                        emitted = true; offset = try add(offset, add(8, skip))
                    }
                }
                switch opcode {
                case 0x00:
                    guard immediate == 0, !lazy || emitted else { throw NativeSignedOutputError.unsupportedClaims }
                    if reader.isPadding { done = true }
                    else {
                        guard lazy else { throw NativeSignedOutputError.unsupportedClaims }
                        segment = nil; offset = 0; ordinal = 0; symbol = false; emitted = false
                    }
                case 0x10:
                    guard immediate > 0, Int(immediate) <= dependencyCount else { throw NativeSignedOutputError.unsupportedClaims }; ordinal = Int(immediate)
                case 0x20:
                    guard immediate == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                    let value = try reader.uleb()
                    guard value > 0, value <= UInt64(dependencyCount) else { throw NativeSignedOutputError.unsupportedClaims }; ordinal = Int(value)
                case 0x40:
                    guard immediate == 0 else { throw NativeSignedOutputError.unsupportedClaims }; try reader.symbol(); symbol = true
                case 0x50:
                    guard immediate == 1 else { throw NativeSignedOutputError.unsupportedClaims }
                case 0x70:
                    guard Int(immediate) < segments.count else { throw NativeSignedOutputError.unsupportedClaims }
                    segment = Int(immediate); offset = try reader.uleb()
                case 0x80:
                    guard immediate == 0, segment != nil else { throw NativeSignedOutputError.unsupportedClaims }
                    offset = try add(offset, reader.uleb())
                case 0x90:
                    guard immediate == 0 else { throw NativeSignedOutputError.unsupportedClaims }; try perform(1, skip: 0)
                case 0xa0:
                    guard immediate == 0 else { throw NativeSignedOutputError.unsupportedClaims }; try perform(1, skip: reader.uleb())
                case 0xb0: try perform(1, skip: UInt64(immediate) * 8)
                case 0xc0:
                    guard immediate == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                    let count = try reader.uleb(); let skip = try reader.uleb(); try perform(count, skip: skip)
                default:
                    // Includes special ordinals, nonzero/explicit addends,
                    // weak-symbol flags, threaded and unknown opcode forms.
                    throw NativeSignedOutputError.unsupportedClaims
                }
                if done { break }
            }
            guard done else { throw NativeSignedOutputError.unsupportedClaims }
        }
        try bindings(bind, lazy: false)
        try bindings(lazyBind, lazy: true)
    }
}
