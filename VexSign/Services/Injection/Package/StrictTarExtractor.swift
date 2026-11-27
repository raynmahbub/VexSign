// MARK: - Strict TAR extraction for tweak packages
//
// Tweak archives are untrusted. Unlike the general IPA path this extractor
// refuses, rather than skips, any entry it cannot represent safely: a symlink,
// a hard link, a device node, a traversal path or an ambiguous path. It writes
// only into a caller-owned temporary directory and cleans that directory if
// any check fails.

import Foundation
import SWCompression

enum StrictTarExtractorError: LocalizedError, Equatable {
    case unsafeEntry(String)
    case tooManyEntries
    case expandedTooLarge
    case depthExceeded(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unsafeEntry(let name):
            "The package contains an unsafe archive entry: \(name). Nothing was installed."
        case .tooManyEntries:
            "The package contains too many files to inspect safely."
        case .expandedTooLarge:
            "The package expands beyond the safe inspection limit."
        case .depthExceeded(let name):
            "The package contains a path nested deeper than VexSign accepts: \(name)."
        case .unsupportedFormat:
            "The package uses a compression format VexSign cannot decode."
        }
    }
}

enum StrictTarExtractor {
    struct Limits: Equatable, Sendable {
        var maximumEntries = 8_192
        var maximumExpandedBytes = 256 * 1024 * 1024
        var maximumDepth = 48

        static let `default` = Limits()
    }

    /// Expands one `.deb` member into `directory` and returns that directory.
    /// `memberName` is used only as a compression hint; the bytes decide format.
    static func extract(
        memberData: Data,
        memberName: String,
        into directory: URL,
        limits: Limits = .default,
        fileManager: FileManager = .default
    ) throws -> URL {
        let tarData: Data
        if memberName == "data.tar" || memberName == "control.tar" || _looksLikeTar(memberData) {
            tarData = memberData
        } else {
            do { tarData = try decompressArchiveData(memberData, extensionHint: (memberName as NSString).pathExtension) }
            catch ArchiveExtractionError.expandedTooLarge { throw StrictTarExtractorError.expandedTooLarge }
            catch { throw StrictTarExtractorError.unsupportedFormat }
        }

        let container: [TarEntry]
        do { container = try TarContainer.open(container: tarData) }
        catch { throw StrictTarExtractorError.unsupportedFormat }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.standardizedFileURL.path
        var entryCount = 0
        var expanded = 0

        do {
            for entry in container {
                entryCount += 1
                guard entryCount <= limits.maximumEntries else { throw StrictTarExtractorError.tooManyEntries }
                let name = entry.info.name
                guard _isSafeArchiveEntryName(name) else { throw StrictTarExtractorError.unsafeEntry(name) }
                let components = name.split(separator: "/", omittingEmptySubsequences: true)
                guard components.count <= limits.maximumDepth else { throw StrictTarExtractorError.depthExceeded(name) }
                guard entry.info.type == .regular || entry.info.type == .directory else {
                    // Symlinks, hard links, FIFOs and devices are never materialised.
                    throw StrictTarExtractorError.unsafeEntry(name)
                }

                let destination = directory.appendingPathComponent(name).standardizedFileURL
                guard destination.path.hasPrefix(root + "/") || destination.path == root else {
                    throw StrictTarExtractorError.unsafeEntry(name)
                }

                if entry.info.type == .directory {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    continue
                }
                guard let data = entry.data else { throw StrictTarExtractorError.unsafeEntry(name) }
                expanded += data.count
                guard expanded <= limits.maximumExpandedBytes else { throw StrictTarExtractorError.expandedTooLarge }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
        } catch {
            try? fileManager.removeItem(at: directory) // try? ok: best-effort cleanup after a rejected archive
            throw error
        }
        return directory
    }

    private static func _looksLikeTar(_ data: Data) -> Bool {
        guard data.count > 262 else { return false }
        return data[257..<262].map { $0 } == [UInt8]("ustar".utf8)
    }
}
