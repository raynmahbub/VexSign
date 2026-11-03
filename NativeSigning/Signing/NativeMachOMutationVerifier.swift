import Foundation

/// Narrow structural/mutation evidence, not proof of all dyld semantics, publisher
/// trust, requirements, resource seals, certificate status or installation rights.
struct NativeMachOMutationEvidence: Sendable {
    let originalSHA256: String
    let outputSHA256: String
    let textFileRange: Range<Int>
    let signatureRange: Range<Int>
    fileprivate init(original: Data, output: Data, layout: NativeMachOSigningLayout) {
        originalSHA256 = NativeSigningIdentityOwner.hash(original)
        outputSHA256 = NativeSigningIdentityOwner.hash(output)
        textFileRange = layout.textFileRange; signatureRange = layout.signatureRange
    }
}

/// First supported concrete mutation dialect requires an EXISTING signature load
/// command and terminal __LINKEDIT signature allocation. No inserting commands,
/// moving code/data, rewriting UUID/dependencies/entrypoints, or decryption.
struct NativeMachOMutationVerifier {
    static func verify(original: Data, output: Data) throws -> NativeMachOMutationEvidence {
        let before = try NativeMachOSigningLayout.inspect(original)
        let after = try NativeMachOSigningLayout.inspect(output)
        guard before.mutableRanges == after.mutableRanges,
              before.signatureRange.lowerBound == after.signatureRange.lowerBound,
              before.textFileRange == after.textFileRange else { throw NativeSignedOutputError.unsupportedClaims }
        // Canonical first slice: preserve the entire pre-signature image, except
        // the exact two __LINKEDIT sizes and LC_CODE_SIGNATURE offset/size fields.
        let end = before.signatureRange.lowerBound
        func equal(_ range: Range<Int>) -> Bool {
            original.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
                output.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                    UnsafeRawBufferPointer(rebasing: a[range]).elementsEqual(UnsafeRawBufferPointer(rebasing: b[range]))
                }
            }
        }
        var cursor = 0
        for range in before.mutableRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            try Task.checkCancellation()
            guard range.lowerBound >= cursor, range.upperBound <= end,
                  equal(cursor..<range.lowerBound) else {
                throw NativeSignedOutputError.unsupportedClaims
            }
            cursor = range.upperBound
        }
        guard equal(cursor..<end) else { throw NativeSignedOutputError.unsupportedClaims }
        return NativeMachOMutationEvidence(original: original, output: output, layout: after)
    }
}

struct NativeMachOSigningLayout: Sendable {
    let textFileRange: Range<Int>
    let signatureRange: Range<Int>
    let instructionFileRanges: [Range<Int>]
    let mutableRanges: [Range<Int>]

    static func inspect(_ data: Data) throws -> Self {
        try Task.checkCancellation()
        guard (32...64 * 1024 * 1024).contains(data.count) else { throw NativeSignedOutputError.unsupportedClaims }
        let bytes = Array(data)
        func u32(_ p: Int) throws -> UInt64 {
            guard p >= 0, p <= bytes.count - 4 else { throw NativeSignedOutputError.unsupportedClaims }
            return UInt64(bytes[p]) | UInt64(bytes[p + 1]) << 8 | UInt64(bytes[p + 2]) << 16 | UInt64(bytes[p + 3]) << 24
        }
        func u64(_ p: Int) throws -> UInt64 { try u32(p) | u32(p + 4) << 32 }
        func fileRange(_ offset: UInt64, _ count: UInt64) throws -> Range<Int> {
            guard offset <= UInt64(bytes.count), count <= UInt64(bytes.count) - offset else { throw NativeSignedOutputError.unsupportedClaims }
            return Int(offset)..<Int(offset + count)
        }
        func name(_ p: Int) throws -> String {
            guard p >= 0, p <= bytes.count - 16 else { throw NativeSignedOutputError.unsupportedClaims }
            let raw = Array(bytes[p..<(p + 16)])
            let end = raw.firstIndex(of: 0) ?? 16
            guard end > 0, raw[end...].allSatisfy({ $0 == 0 }), raw[..<end].allSatisfy({ (33...126).contains($0) }),
                  let value = String(bytes: raw[..<end], encoding: .ascii) else { throw NativeSignedOutputError.unsupportedClaims }
            return value
        }
        guard try u32(0) == 0xfeedfacf, try u32(4) == 0x0100000c, try u32(8) == 0,
              try u32(12) == 2, try u32(24) & 0x20100 == 0, try u32(28) == 0 else { throw NativeSignedOutputError.unsupportedClaims }
        let count = Int(try u32(16)); let size = Int(try u32(20))
        guard count > 0, count <= 1024, size <= 1024 * 1024, size <= bytes.count - 32 else { throw NativeSignedOutputError.unsupportedClaims }
        let commandsEnd = 32 + size
        struct Segment {
            let name: String
            let file: Range<Int>
            let vm: Range<UInt64>
            let protections: UInt64
        }
        var segments: [Segment] = []; var segmentNames = Set<String>()
        var signature: Range<Int>?; var mutable: [Range<Int>] = []; var entry: UInt64?
        var instructionRanges: [Range<Int>] = []; var encryptionSeen = false
        var cursor = 32
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor <= commandsEnd - 8 else { throw NativeSignedOutputError.unsupportedClaims }
            let command = try u32(cursor); let length = Int(try u32(cursor + 4))
            guard length >= 8, length % 8 == 0, length <= commandsEnd - cursor else { throw NativeSignedOutputError.unsupportedClaims }
            switch command {
            case 0x19: // LC_SEGMENT_64
                guard length >= 72 else { throw NativeSignedOutputError.unsupportedClaims }
                let segmentName = try name(cursor + 8)
                let vmStart = try u64(cursor + 24); let vmSize = try u64(cursor + 32)
                let file = try fileRange(u64(cursor + 40), u64(cursor + 48))
                let maxProtection = try u32(cursor + 56); let protection = try u32(cursor + 60)
                let sections = Int(try u32(cursor + 64))
                guard segmentNames.insert(segmentName).inserted, vmSize > 0, vmSize <= UInt64.max - vmStart,
                      UInt64(file.count) <= vmSize, vmStart % 4096 == 0, vmSize % 4096 == 0,
                      file.lowerBound % 4096 == 0, maxProtection & ~UInt64(7) == 0,
                      protection & ~maxProtection == 0, maxProtection & 6 != 6,
                      sections <= 256, length == 72 + sections * 80,
                      try u32(cursor + 68) == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                let vm = vmStart..<(vmStart + vmSize)
                guard !segments.contains(where: { $0.vm.overlaps(vm) || (!$0.file.isEmpty && !file.isEmpty && $0.file.overlaps(file)) }) else {
                    throw NativeSignedOutputError.unsupportedClaims
                }
                if segmentName == "__PAGEZERO" {
                    guard file.isEmpty, file.lowerBound == 0, protection == 0, maxProtection == 0, sections == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                } else {
                    guard !file.isEmpty, protection & 1 != 0 else { throw NativeSignedOutputError.unsupportedClaims }
                }
                var sectionVMs: [Range<UInt64>] = []
                for i in 0..<sections {
                    let p = cursor + 72 + i * 80
                    _ = try name(p)
                    guard try name(p + 16) == segmentName else { throw NativeSignedOutputError.unsupportedClaims }
                    let address = try u64(p + 32); let sectionSize = try u64(p + 40)
                    let offset = try u32(p + 48); let alignment = try u32(p + 52)
                    let type = try u32(p + 64) & 0xff
                    guard address >= vm.lowerBound, address <= vm.upperBound, sectionSize <= vm.upperBound - address,
                          alignment <= 14, address % (UInt64(1) << alignment) == 0,
                          try u32(p + 56) == 0, try u32(p + 60) == 0,
                          !sectionVMs.contains(where: { $0.overlaps(address..<(address + sectionSize)) }) else { throw NativeSignedOutputError.unsupportedClaims }
                    sectionVMs.append(address..<(address + sectionSize))
                    if [UInt64(1), 12, 18].contains(type) { // zero-fill only
                        guard offset == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                    } else {
                        guard type <= 21, offset >= UInt64(file.lowerBound), offset <= UInt64(file.upperBound),
                              sectionSize <= UInt64(file.upperBound) - offset,
                              offset - UInt64(file.lowerBound) == address - vmStart else { throw NativeSignedOutputError.unsupportedClaims }
                        if protection & 4 != 0, try u32(p + 64) & 0x80000400 != 0, sectionSize > 0 {
                            instructionRanges.append(Int(offset)..<Int(offset + sectionSize))
                        }
                    }
                }
                if segmentName == "__LINKEDIT" {
                    guard sections == 0, protection == 1, maxProtection == 1 else { throw NativeSignedOutputError.unsupportedClaims }
                    mutable += [(cursor + 32)..<(cursor + 40), (cursor + 48)..<(cursor + 56)]
                }
                segments.append(Segment(name: segmentName, file: file, vm: vm, protections: protection))
            case 0x1d: // LC_CODE_SIGNATURE
                guard length == 16, signature == nil else { throw NativeSignedOutputError.unsupportedClaims }
                signature = try fileRange(u32(cursor + 8), u32(cursor + 12))
                mutable.append((cursor + 8)..<(cursor + 16))
            case 0x80000028: // LC_MAIN; no LC_UNIXTHREAD alternative
                guard length == 24, entry == nil, try u64(cursor + 16) == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                entry = try u64(cursor + 8)
            case 0x2c: // LC_ENCRYPTION_INFO_64: no DRM decryption
                guard !encryptionSeen, length == 24, try u32(cursor + 16) == 0, try u32(cursor + 20) == 0 else { throw NativeSignedOutputError.unsupportedClaims }
                encryptionSeen = true
                _ = try fileRange(u32(cursor + 8), u32(cursor + 12))
            case 1, 4, 5, 0x21, 0x27, 0x80000035:
                throw NativeSignedOutputError.unsupportedClaims
            default:
                // Other commands are preserved byte-for-byte, NOT semantically
                // authorized here. The dependency/dyld policy is a separate gate.
                break
            }
            cursor += length
        }
        guard cursor == commandsEnd, let signature, signature.count >= 12,
              signature.lowerBound >= commandsEnd, signature.lowerBound % 16 == 0,
              signature.upperBound == bytes.count,
              let text = segments.first(where: { $0.name == "__TEXT" }), text.file.lowerBound == 0,
              text.file.upperBound >= commandsEnd, text.protections == 5,
              let linkedit = segments.first(where: { $0.name == "__LINKEDIT" }),
              linkedit.file.contains(signature.lowerBound), linkedit.file.upperBound == bytes.count,
              let entry, entry >= UInt64(commandsEnd), entry < UInt64(text.file.upperBound), entry % 4 == 0,
              instructionRanges.contains(where: { $0.lowerBound >= commandsEnd && $0.contains(Int(entry)) && $0.upperBound - Int(entry) >= 4 }),
              segments.allSatisfy({ $0.name == "__LINKEDIT" || $0.file.upperBound <= signature.lowerBound }),
              mutable.count == 3 else { throw NativeSignedOutputError.unsupportedClaims }
        return Self(textFileRange: text.file, signatureRange: signature, instructionFileRanges: instructionRanges, mutableRanges: mutable)
    }
}
