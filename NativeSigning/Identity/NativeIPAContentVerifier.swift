import Foundation

/// Complete checksum/content scan for the SUPPORTED single-main-app subset.
/// No extraction, mutation, publisher trust, certificate trust or installation.
/// Exact input bytes must be rebound/rechecked before any later materialization.
struct NativeVerifiedIPAContent: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let archiveSHA256: String
    let appRoot: String
    let executableName: String
    let infoPlist: Data
    let executable: Data
    let entrySHA256: [String: String]
    let expandedBytes: Int
    fileprivate init(index: NativeIPAArchiveIndex, layout: NativeIPAArchiveLayout, executableName: String,
                     infoPlist: Data, executable: Data, hashes: [String: String], expandedBytes: Int) {
        archiveSHA256 = index.archiveSHA256; appRoot = layout.appRoot
        self.executableName = executableName; self.infoPlist = infoPlist; self.executable = executable
        entrySHA256 = hashes; self.expandedBytes = expandedBytes
    }
    var description: String { "NativeVerifiedIPAContent(redacted; not signing authority)" }
    var debugDescription: String { description }


}

struct NativeIPAContentVerifier {
    static func verify(_ archive: Data, bundleIdentifier: String) throws -> NativeVerifiedIPAContent {
        try Task.checkCancellation()
        guard NativeAccountProvisioningRequest.isBundleIdentifier(bundleIdentifier) else { throw NativeIPAArchiveError.unsupportedLayout }
        let index = try NativeIPAArchiveIndex.inspect(archive)
        let layout = try NativeIPAArchiveLayout.singleMainApp(index)
        let info = try NativeIPAEntryDecoder.decode(archive: archive, entry: layout.infoEntry)
        let executableName = try NativeMainAppAcceptance.executableName(infoPlist: info, bundleIdentifier: bundleIdentifier)
        let executablePath = layout.appRoot + "/" + executableName
        guard let main = index.entries.first(where: { $0.path == executablePath && !$0.isDirectory }),
              main.expandedCount > 0, main.expandedCount <= 64 * 1024 * 1024 else { throw NativeIPAArchiveError.unsupportedLayout }
        var hashes: [String: String] = [:]; var executable: Data?; var expanded = 0
        for entry in index.entries {
            try Task.checkCancellation()
            let content: Data
            if entry.path == layout.infoEntry.path { content = info }
            else { content = try NativeIPAEntryDecoder.decode(archive: archive, entry: entry) }
            guard content.count <= 512 * 1024 * 1024 - expanded else { throw NativeIPAArchiveError.resourceLimit }
            expanded += content.count
            if entry.path == executablePath {
                _ = try NativeMachOInspection.inspect(content) // encrypted/unsupported code rejects
                executable = content
            } else if !entry.isDirectory && hasExecutableMagic(content) {
                // A resource renamed to .png/.dat is still code. Do not sign or
                // silently ignore additional Mach-O/fat/static-archive content.
                throw NativeIPAArchiveError.unsupportedLayout
            }
            hashes[entry.path] = NativeSigningIdentityOwner.hash(content)
        }
        guard let executable else { throw NativeIPAArchiveError.unsupportedLayout }
        try Task.checkCancellation()
        return NativeVerifiedIPAContent(index: index, layout: layout, executableName: executableName,
            infoPlist: info, executable: executable, hashes: hashes, expandedBytes: expanded)
    }

    private static func hasExecutableMagic(_ data: Data) -> Bool {
        let prefix = Array(data.prefix(8))
        if prefix == Array("!<arch>\n".utf8) { return true }
        guard prefix.count >= 4 else { return false }
        let magic = Array(prefix.prefix(4))
        return [[UInt8(0xce),0xfa,0xed,0xfe], [0xcf,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xce], [0xfe,0xed,0xfa,0xcf],
                [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]].contains(magic)
    }
}
