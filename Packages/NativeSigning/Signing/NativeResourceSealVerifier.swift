import Foundation
import CryptoKit

/// Complete ZIP transport/resource mutation consistency ONLY. Not a Mach-O or
/// certificate trust verdict, signing permit, sealed IPA or installer input.
struct NativeResourceSealEvidence: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "NativeResourceSealEvidence(redacted; not artifact authority)" }
    var debugDescription: String { description }
    let sourceArchiveSHA256: String
    let outputArchiveSHA256: String
    let executableSHA256: String
    let codeResourcesSHA256: String
    let profileSHA256: String
    fileprivate init(source: String, output: String, executable: String, resources: Data, profile: Data) {
        sourceArchiveSHA256 = source; outputArchiveSHA256 = output; executableSHA256 = executable
        codeResourcesSHA256 = NativeSigningIdentityOwner.hash(resources)
        profileSHA256 = NativeSigningIdentityOwner.hash(profile)
    }
}

/// Bind original content receipt to exact original bytes; preserve every input
/// file/directory except signer-owned signature metadata. Only main executable,
/// exact expected profile and root CodeResources may change. No added resources,
/// changed Info.plist, optional/omit rules or injected nested code are accepted.
struct NativeResourceSealVerifier {
    static func verify(originalArchive: Data, content: NativeVerifiedIPAContent,
                       outputArchive: Data, expectedProfileCMS: Data) throws -> NativeResourceSealEvidence {
        try Task.checkCancellation()
        guard (22...128 * 1024 * 1024).contains(originalArchive.count),
              (22...128 * 1024 * 1024).contains(outputArchive.count),
              NativeSigningIdentityOwner.hash(originalArchive) == content.archiveSHA256,
              !expectedProfileCMS.isEmpty, expectedProfileCMS.count <= 1024 * 1024 else { throw NativeSignedOutputError.unsupportedClaims }
        let original = try NativeIPAArchiveIndex.inspect(originalArchive)
        let output = try NativeIPAArchiveIndex.inspect(outputArchive)
        guard try NativeIPAArchiveLayout.singleMainApp(output).appRoot == content.appRoot else { throw NativeSignedOutputError.unsupportedClaims }
        let prefix = content.appRoot + "/"
        let main = prefix + content.executableName
        let profile = prefix + "embedded.mobileprovision"
        let signatureDirectory = prefix + "_CodeSignature"
        let seal = signatureDirectory + "/CodeResources"
        func signerOwned(_ path: String) -> Bool { path == signatureDirectory || path.hasPrefix(signatureDirectory + "/") }
        let originalByPath = Dictionary(uniqueKeysWithValues: original.entries.map { ($0.path, $0) })
        let outputByPath = Dictionary(uniqueKeysWithValues: output.entries.map { ($0.path, $0) })
        guard Set(content.entrySHA256.keys) == Set(originalByPath.keys),
              let mainEntry = outputByPath[main], !mainEntry.isDirectory, mainEntry.expandedCount > 0,
              mainEntry.expandedCount <= 64 * 1024 * 1024,
              let profileEntry = outputByPath[profile], !profileEntry.isDirectory,
              let sealEntry = outputByPath[seal], !sealEntry.isDirectory,
              sealEntry.expandedCount > 0, sealEntry.expandedCount <= 4 * 1024 * 1024 else { throw NativeSignedOutputError.unsupportedClaims }
        for entry in original.entries where !signerOwned(entry.path) {
            guard let after = outputByPath[entry.path], after.isDirectory == entry.isDirectory else { throw NativeSignedOutputError.unsupportedClaims }
        }
        var resources: [String: NativeStrictCodeResources.Digests] = [:]
        var actualSeal: Data?; var executableSHA256: String?
        for entry in output.entries {
            try Task.checkCancellation()
            if signerOwned(entry.path) {
                guard entry.path == seal || (entry.path == signatureDirectory && entry.isDirectory) else { throw NativeSignedOutputError.unsupportedClaims }
            } else {
                guard originalByPath[entry.path] != nil || entry.path == profile else { throw NativeSignedOutputError.unsupportedClaims }
            }
            let bytes = try NativeIPAEntryDecoder.decode(archive: outputArchive, entry: entry)
            let hash = NativeSigningIdentityOwner.hash(bytes)
            if entry.path == profile {
                guard bytes == expectedProfileCMS else { throw NativeSignedOutputError.unsupportedClaims }
            } else if entry.path == seal { actualSeal = bytes }
            else if entry.path == main { executableSHA256 = hash }
            else if !signerOwned(entry.path) {
                guard hash == content.entrySHA256[entry.path] else { throw NativeSignedOutputError.unsupportedClaims }
            }
            if !entry.isDirectory, entry.path != main, !signerOwned(entry.path) {
                guard entry.path.hasPrefix(prefix) else { throw NativeSignedOutputError.unsupportedClaims }
                let relative = String(entry.path.dropFirst(prefix.count))
                // Seal Info.plist and exact embedded profile too, not optional.
                resources[relative] = .init(sha1: Data(Insecure.SHA1.hash(data: bytes)), sha256: Data(SHA256.hash(data: bytes)))
            }
        }
        guard let actualSeal, let executableSHA256,
              try NativeStrictCodeResources.encode(resources) == actualSeal else { throw NativeSignedOutputError.unsupportedClaims }
        try Task.checkCancellation()
        return NativeResourceSealEvidence(source: content.archiveSHA256, output: output.archiveSHA256,
            executable: executableSHA256, resources: actualSeal, profile: expectedProfileCMS)
    }
}
