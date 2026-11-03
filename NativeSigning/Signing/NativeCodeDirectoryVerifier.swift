import Foundation
import CryptoKit

public enum NativeSignedOutputError: Error, Equatable, Sendable {
    case invalidDirectory, invalidSignature, unsupportedClaims
}

/// Byte/hash consistency evidence, NOT verified whole-Mach-O or IPA output.
struct NativeCodeDirectoryEvidence: Sendable {
    let directorySHA256: String
    let executablePrefixSHA256: String
    fileprivate init(directory: Data, executablePrefix: Data) {
        directorySHA256 = NativeSigningIdentityOwner.hash(directory)
        executablePrefixSHA256 = NativeSigningIdentityOwner.hash(executablePrefix)
    }
}

/// Independent narrow v0x20400 SHA256 CodeDirectory verifier. The future output
/// assembler must extract the exact prefix from validated LC_CODE_SIGNATURE,
/// validate segments/entrypoint/mutations/resources, authenticate detached CMS
/// and revalidate live authority. This function alone grants NO artifact release.
struct NativeCodeDirectoryVerifier {
    static func verify(_ directory: Data, executablePrefix: Data, bundleIdentifier: String,
                       teamIdentifier: String, textFileRange: Range<Int>,
                       specialSlotBlobs: [Int: Data]) throws -> NativeCodeDirectoryEvidence {
        try Task.checkCancellation()
        guard (88...1024 * 1024).contains(directory.count), !executablePrefix.isEmpty,
              executablePrefix.count <= 64 * 1024 * 1024,
              NativeAccountProvisioningRequest.isBundleIdentifier(bundleIdentifier),
              teamIdentifier.utf8.count == 10, teamIdentifier.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              textFileRange.lowerBound >= 0, !textFileRange.isEmpty,
              textFileRange.upperBound <= executablePrefix.count,
              Set(specialSlotBlobs.keys) == Set([1, 2, 3, 5, 7]),
              specialSlotBlobs.values.allSatisfy({ !$0.isEmpty && $0.count <= 4 * 1024 * 1024 }) else { throw NativeSignedOutputError.invalidDirectory }
        let bytes = Array(directory)
        func word(_ offset: Int) -> Int {
            Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        func wide(_ offset: Int) -> UInt64 { UInt64(word(offset)) << 32 | UInt64(word(offset + 4)) }
        guard word(0) == 0xfade0c02, word(4) == bytes.count, word(8) == 0x20400,
              word(12) == 0, word(20) == 88, word(24) == 7,
              word(32) == executablePrefix.count, bytes[36] == 32, bytes[37] == 2,
              bytes[38] == 0, [UInt8(12), 14].contains(bytes[39]),
              word(40) == 0, word(44) == 0, word(52) == 0, wide(56) == 0,
              wide(64) == UInt64(textFileRange.lowerBound), wide(72) == UInt64(textFileRange.count),
              wide(80) == 1 else { throw NativeSignedOutputError.unsupportedClaims }
        // MAIN_BINARY only: no allow-unsigned, JIT, debugger or library-validation
        // bypass flags. Upstream's broader execSeg flags are deliberately rejected.
        let identifier = Data(bundleIdentifier.utf8) + Data([0])
        let team = Data(teamIdentifier.utf8) + Data([0])
        let stringsEnd = 88 + identifier.count + team.count
        let hashOffset = stringsEnd + 7 * 32
        let pageSize = 1 << Int(bytes[39])
        let pages = (executablePrefix.count + pageSize - 1) / pageSize
        guard word(48) == 88 + identifier.count, word(16) == hashOffset,
              word(28) == pages, bytes.count == hashOffset + pages * 32,
              Data(bytes[88..<(88 + identifier.count)]) == identifier,
              Data(bytes[(88 + identifier.count)..<stringsEnd]) == team else { throw NativeSignedOutputError.invalidDirectory }
        for slot in 1...7 {
            let expected = specialSlotBlobs[slot].map { Data(SHA256.hash(data: $0)) } ?? Data(repeating: 0, count: 32)
            let start = hashOffset - slot * 32
            guard Data(bytes[start..<(start + 32)]) == expected else { throw NativeSignedOutputError.invalidDirectory }
        }
        for page in 0..<pages {
            try Task.checkCancellation()
            let start = page * pageSize
            let expected = Data(SHA256.hash(data: executablePrefix.subdata(in: start..<min(start + pageSize, executablePrefix.count))))
            let offset = hashOffset + page * 32
            guard Data(bytes[offset..<(offset + 32)]) == expected else { throw NativeSignedOutputError.invalidDirectory }
        }
        return NativeCodeDirectoryEvidence(directory: directory, executablePrefix: executablePrefix)
    }
}
