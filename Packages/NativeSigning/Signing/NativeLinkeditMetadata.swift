import Foundation

/// Remaining supported linkedit metadata dialects: canonical ARM64 function
/// deltas and bounded data-in-code records. Not executable instruction analysis.
struct NativeLinkeditMetadata {
    static func functions(_ payload: Data, image: Data) throws {
        let layout = try NativeMachOSigningLayout.inspect(image)
        guard payload.count <= 4 * 1024 * 1024 else { throw NativeSignedOutputError.unsupportedClaims }
        if payload.isEmpty { return }
        let bytes = Array(payload)
        var cursor = 0; var address = 0; var count = 0; var done = false
        while cursor < bytes.count {
            try Task.checkCancellation()
            var delta: UInt64 = 0; var decoded = false
            for i in 0..<10 {
                guard cursor < bytes.count else { throw NativeSignedOutputError.unsupportedClaims }
                let byte = bytes[cursor]; cursor += 1
                let value = byte & 127
                guard i < 9 || value <= 1 else { throw NativeSignedOutputError.unsupportedClaims }
                delta |= UInt64(value) << (i * 7)
                if byte & 128 == 0 {
                    guard i == 0 || value != 0 else { throw NativeSignedOutputError.unsupportedClaims }
                    decoded = true; break
                }
            }
            guard decoded else { throw NativeSignedOutputError.unsupportedClaims }
            if delta == 0 {
                guard bytes.count - cursor <= 7, bytes[cursor...].allSatisfy({ $0 == 0 }) else { throw NativeSignedOutputError.unsupportedClaims }
                done = true; break
            }
            guard delta <= UInt64(layout.textFileRange.upperBound - address), count < 262144 else { throw NativeSignedOutputError.unsupportedClaims }
            address += Int(delta); count += 1
            guard address % 4 == 0, layout.instructionFileRanges.contains(where: { $0.contains(address) && $0.upperBound - address >= 4 }) else { throw NativeSignedOutputError.unsupportedClaims }
        }
        guard done else { throw NativeSignedOutputError.unsupportedClaims }
    }

    static func dataInCode(_ payload: Data, image: Data) throws {
        let layout = try NativeMachOSigningLayout.inspect(image)
        guard payload.count <= 4 * 1024 * 1024, payload.count % 8 == 0 else { throw NativeSignedOutputError.unsupportedClaims }
        let bytes = Array(payload)
        var previousEnd = 0
        for p in stride(from: 0, to: bytes.count, by: 8) {
            try Task.checkCancellation()
            let start = Int(bytes[p]) | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]) << 16 | Int(bytes[p + 3]) << 24
            let length = Int(bytes[p + 4]) | Int(bytes[p + 5]) << 8
            let kind = Int(bytes[p + 6]) | Int(bytes[p + 7]) << 8
            guard length > 0, (1...5).contains(kind), start >= previousEnd,
                  start <= layout.textFileRange.upperBound, length <= layout.textFileRange.upperBound - start,
                  layout.instructionFileRanges.contains(where: { start >= $0.lowerBound && start + length <= $0.upperBound }) else {
                throw NativeSignedOutputError.unsupportedClaims
            }
            let alignment = kind == 3 ? 2 : ((kind == 4 || kind == 5) ? 4 : 1)
            guard start % alignment == 0, length % alignment == 0 else { throw NativeSignedOutputError.unsupportedClaims }
            previousEnd = start + length
        }
    }
}
