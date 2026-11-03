import Foundation

public enum NativeSigningAcceptanceError: Error, Equatable, Sendable {
    case invalidInput, unsupportedExecutable, encryptedExecutable, malformedSignature
    case unsupportedEntitlements, profileMismatch, expired
}

/// Main-executable inspection only, NOT an archive inventory, original-signature
/// trust verdict or permission to sign. Initial subset is thin ARM64 MH_EXECUTE.
struct NativeMachOInspection: Sendable {
    let entitlementsXML: Data?

    static func inspect(_ data: Data) throws -> Self {
        guard data.count >= 32, data.count <= 64 * 1024 * 1024 else { throw NativeSigningAcceptanceError.invalidInput }
        let bytes = Array(data)
        func word(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - 4 else { throw NativeSigningAcceptanceError.unsupportedExecutable }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        guard try word(0) == 0xfeedfacf, try word(4) == 0x0100000c,
              try word(8) == 0, try word(12) == 2 else { throw NativeSigningAcceptanceError.unsupportedExecutable }
        let count = try word(16); let size = try word(20)
        guard count > 0, count <= 1024, size <= 1024 * 1024, size <= bytes.count - 32 else { throw NativeSigningAcceptanceError.unsupportedExecutable }
        let end = 32 + size
        var cursor = 32; var signature: Range<Int>?; var encryptionSeen = false
        for _ in 0..<count {
            guard cursor <= end - 8 else { throw NativeSigningAcceptanceError.unsupportedExecutable }
            let command = try word(cursor); let length = try word(cursor + 4)
            guard length >= 8, length % 8 == 0, length <= end - cursor else { throw NativeSigningAcceptanceError.unsupportedExecutable }
            if command == 0x21 { throw NativeSigningAcceptanceError.unsupportedExecutable } // 32-bit encryption info
            if command == 0x2c { // LC_ENCRYPTION_INFO_64: never decrypt/bypass DRM
                guard !encryptionSeen, length == 24 else { throw NativeSigningAcceptanceError.unsupportedExecutable }
                encryptionSeen = true
                guard try word(cursor + 16) == 0 else { throw NativeSigningAcceptanceError.encryptedExecutable }
                let offset = try word(cursor + 8); let length = try word(cursor + 12)
                guard offset <= bytes.count, length <= bytes.count - offset else { throw NativeSigningAcceptanceError.unsupportedExecutable }
            }
            if command == 0x1d { // LC_CODE_SIGNATURE
                guard signature == nil, length == 16 else { throw NativeSigningAcceptanceError.malformedSignature }
                let offset = try word(cursor + 8); let length = try word(cursor + 12)
                guard offset >= end, offset <= bytes.count, length >= 12,
                      length <= 4 * 1024 * 1024, length <= bytes.count - offset else { throw NativeSigningAcceptanceError.malformedSignature }
                signature = offset..<(offset + length)
            }
            cursor += length
        }
        guard cursor == end else { throw NativeSigningAcceptanceError.unsupportedExecutable }
        guard let signature else { return Self(entitlementsXML: nil) }
        return Self(entitlementsXML: try entitlements(Data(bytes[signature])))
    }

    private static func entitlements(_ blob: Data) throws -> Data? {
        let bytes = Array(blob)
        func word(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - 4 else { throw NativeSigningAcceptanceError.malformedSignature }
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        guard try word(0) == 0xfade0cc0 else { throw NativeSigningAcceptanceError.malformedSignature }
        let length = try word(4); let count = try word(8)
        guard length >= 12, length <= bytes.count, count <= 64, count <= (length - 12) / 8 else { throw NativeSigningAcceptanceError.malformedSignature }
        // LC_CODE_SIGNATURE allocation may contain alignment padding, not more blobs.
        guard bytes[length...].allSatisfy({ $0 == 0 }) else { throw NativeSigningAcceptanceError.malformedSignature }
        let tableEnd = 12 + count * 8
        var slots = Set<Int>(); var ranges: [Range<Int>] = []; var xml: Data?
        for index in 0..<count {
            let slot = try word(12 + index * 8); let offset = try word(16 + index * 8)
            guard slots.insert(slot).inserted, offset >= tableEnd, offset <= length - 8 else { throw NativeSigningAcceptanceError.malformedSignature }
            let magic = try word(offset); let size = try word(offset + 4)
            guard size >= 8, size <= length - offset else { throw NativeSigningAcceptanceError.malformedSignature }
            let range = offset..<(offset + size)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw NativeSigningAcceptanceError.malformedSignature }
            ranges.append(range)
            // Never silently discard DER-only or dual XML/DER entitlement claims.
            if slot == 7 || magic == 0xfade7172 { throw NativeSigningAcceptanceError.unsupportedEntitlements }
            if slot == 5 || magic == 0xfade7171 {
                guard slot == 5, magic == 0xfade7171, xml == nil, size > 8, size <= 64 * 1024 else { throw NativeSigningAcceptanceError.malformedSignature }
                let value = Data(bytes[(offset + 8)..<(offset + size)])
                guard value.starts(with: Data("<?xml".utf8)) else { throw NativeSigningAcceptanceError.unsupportedEntitlements }
                xml = value
            }
        }
        return xml
    }
}
