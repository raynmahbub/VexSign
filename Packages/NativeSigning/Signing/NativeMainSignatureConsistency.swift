import Foundation

/// Composed signature consistency only. Still not whole-Mach-O semantics,
/// certificate trust/current authority, complete
/// archive binding or permission to release an installation artifact.
struct NativeMainSignatureConsistencyEvidence: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "NativeMainSignatureConsistencyEvidence(redacted; not artifact authority)" }
    var debugDescription: String { description }
    let signatureSHA256: String
    let executablePrefixSHA256: String
    let codeDirectorySHA256: String
    let certificateSHA256: String
    let infoSHA256: String
    let resourcesSHA256: String
    let requirementsSHA256: String
    fileprivate init(signature: Data, directory: NativeCodeDirectoryEvidence,
                     cms: NativeDetachedCodeSignatureEvidence, info: Data, resources: Data, requirements: Data) {
        signatureSHA256 = NativeSigningIdentityOwner.hash(signature)
        executablePrefixSHA256 = directory.executablePrefixSHA256
        codeDirectorySHA256 = directory.directorySHA256; certificateSHA256 = cms.certificateSHA256
        infoSHA256 = NativeSigningIdentityOwner.hash(info); resourcesSHA256 = NativeSigningIdentityOwner.hash(resources)
        requirementsSHA256 = NativeSigningIdentityOwner.hash(requirements)
    }
}

struct NativeMainSignatureConsistency {
    /// Real image-bound entry point, not caller-invented prefix/signature slices.
    /// Still requires independent dyld/dependency/current-authority gates.
    static func verifyMutationAndSignature(original: Data, output: Data,
                       infoPlist: Data, codeResources: Data, expectedXML: Data,
                       bundleIdentifier: String, teamIdentifier: String,
                       expectedCertificate: Data) throws -> NativeMainSignatureConsistencyEvidence {
        try NativeMachOLoaderPolicy.validate(original)
        try NativeMachOLoaderPolicy.validate(output)
        let mutation = try NativeMachOMutationVerifier.verify(original: original, output: output)
        return try verify(signature: output.subdata(in: mutation.signatureRange),
            executablePrefix: output.subdata(in: 0..<mutation.signatureRange.lowerBound),
            textFileRange: mutation.textFileRange, infoPlist: infoPlist, codeResources: codeResources,
            expectedXML: expectedXML, bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier,
            expectedCertificate: expectedCertificate)
    }

    static func verify(signature: Data, executablePrefix: Data, textFileRange: Range<Int>,
                       infoPlist: Data, codeResources: Data, expectedXML: Data,
                       bundleIdentifier: String, teamIdentifier: String,
                       expectedCertificate: Data) throws -> NativeMainSignatureConsistencyEvidence {
        try Task.checkCancellation()
        guard (12...4 * 1024 * 1024).contains(signature.count),
              !infoPlist.isEmpty, infoPlist.count <= 256 * 1024,
              !codeResources.isEmpty, codeResources.count <= 4 * 1024 * 1024 else { throw NativeSignedOutputError.invalidSignature }
        let bytes = Array(signature)
        func word(_ p: Int) throws -> Int {
            guard p >= 0, p <= bytes.count - 4 else { throw NativeSignedOutputError.invalidSignature }
            return Int(bytes[p]) << 24 | Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
        }
        guard try word(0) == 0xfade0cc0 else { throw NativeSignedOutputError.invalidSignature }
        let length = try word(4); let count = try word(8)
        guard count == 5, length >= 52, length <= bytes.count,
              bytes[length...].allSatisfy({ $0 == 0 }) else { throw NativeSignedOutputError.invalidSignature }
        let expectedMagics = [0: 0xfade0c02, 2: 0xfade0c01, 5: 0xfade7171, 7: 0xfade7172, 0x10000: 0xfade0b01]
        var blobs: [Int: Data] = [:]; var ranges: [Range<Int>] = []
        for index in 0..<count {
            let slot = try word(12 + index * 8); let start = try word(16 + index * 8)
            guard let magic = expectedMagics[slot], blobs[slot] == nil,
                  start >= 52, start <= length - 8,
                  try word(start) == magic else { throw NativeSignedOutputError.invalidSignature }
            let size = try word(start + 4)
            guard size >= 8, size <= length - start else { throw NativeSignedOutputError.invalidSignature }
            let range = start..<(start + size)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw NativeSignedOutputError.invalidSignature }
            ranges.append(range); blobs[slot] = Data(bytes[range])
        }
        // No hidden/gap payload, duplicate or alternate CodeDirectories.
        var end = 52
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound == end else { throw NativeSignedOutputError.invalidSignature }
            end = range.upperBound
        }
        guard end == length, let directory = blobs[0], let requirements = blobs[2],
              let xml = blobs[5], let der = blobs[7], let cms = blobs[0x10000] else { throw NativeSignedOutputError.invalidSignature }
        try NativeDesignatedRequirement.verify(requirements, bundleIdentifier: bundleIdentifier, certificateDER: expectedCertificate)
        try NativeOutputEntitlements.verify(xmlBlob: xml, derBlob: der, expectedXML: expectedXML,
            applicationIdentifier: teamIdentifier + "." + bundleIdentifier, teamIdentifier: teamIdentifier)
        let directoryEvidence = try NativeCodeDirectoryVerifier.verify(directory, executablePrefix: executablePrefix,
            bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier, textFileRange: textFileRange,
            specialSlotBlobs: [1: infoPlist, 2: requirements, 3: codeResources, 5: xml, 7: der])
        let cmsEvidence = try NativeDetachedCodeSignatureVerifier.verify(cms: Data(cms.dropFirst(8)),
            codeDirectory: directory, expectedCertificate: expectedCertificate)
        guard directoryEvidence.directorySHA256 == cmsEvidence.codeDirectorySHA256 else { throw NativeSignedOutputError.invalidSignature }
        try Task.checkCancellation()
        return NativeMainSignatureConsistencyEvidence(signature: signature, directory: directoryEvidence, cms: cmsEvidence,
            info: infoPlist, resources: codeResources, requirements: requirements)
    }
}
