//
//  ArchiveSafetyValidator.swift
//  VexSign
//
//  Validates untrusted ZIP metadata before the extraction backends run. ZIP
//  archives can contain traversal paths, symlinks or extreme expansion ratios;
//  rejecting those entries before Zip.unzipFile prevents them from writing
//  outside the intended workspace.
//

import Foundation
import ZIPFoundation
import NimbleExtensions

struct ArchiveSafetyValidator {
    enum ValidationError: LocalizedError {
        case unreadable
        case absolutePath(String)
        case traversalPath(String)
        case symbolicLink(String)
        case tooManyEntries
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return .localized("This archive could not be inspected safely.")
            case .absolutePath(let path):
                return .localized("The archive contains an unsafe absolute path: %@", arguments: path)
            case .traversalPath(let path):
                return .localized("The archive contains an unsafe path: %@", arguments: path)
            case .symbolicLink(let path):
                return .localized("The archive contains an unsupported symbolic link: %@", arguments: path)
            case .tooManyEntries:
                return .localized("The archive contains too many files to extract safely.")
            case .tooLarge:
                return .localized("The archive expands beyond the safe extraction limit.")
            }
        }
    }

    // These limits are deliberately generous for IPA files while preventing
    // accidental archive bombs from consuming unbounded storage.
    private static let maxEntries = 50_000
    private static let maxUncompressedBytes: UInt64 = 8 * 1024 * 1024 * 1024

    static func validate(_ archiveURL: URL, destination: URL? = nil) throws {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw ValidationError.unreadable
        }

        let root = destination ?? archiveURL.deletingLastPathComponent()
        var entryCount = 0
        var uncompressedBytes: UInt64 = 0

        for entry in archive {
            entryCount += 1
            guard entryCount <= maxEntries else { throw ValidationError.tooManyEntries }

            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            if path.hasPrefix("/") || path.hasPrefix("~") {
                throw ValidationError.absolutePath(path)
            }
            if path.unicodeScalars.contains(where: { $0.value == 0 }) {
                throw ValidationError.traversalPath(path)
            }

            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.contains(where: { $0 == ".." || $0 == "." }) else {
                throw ValidationError.traversalPath(path)
            }

            if entry.type == .symlink {
                throw ValidationError.symbolicLink(path)
            }

            guard entry.uncompressedSize <= maxUncompressedBytes - min(uncompressedBytes, maxUncompressedBytes) else {
                throw ValidationError.tooLarge
            }
            uncompressedBytes += entry.uncompressedSize

            try validateDestination(relativePath: components.map(String.init).joined(separator: "/"), root: root)

        }
    }
    /// Normalize the base before appending, so Foundation cannot resolve an
    /// alias such as /var -> /private/var on only one side of the comparison.
    /// Compare path components, not string prefixes ("work-other" is not "work").
    static func validateDestination(relativePath: String, root: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\0"),
              !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.contains(":") }) else {
            throw ValidationError.traversalPath(relativePath)
        }

        // `resolvingSymlinksInPath()` cannot resolve an intermediate link when
        // the final component does not exist yet, which is exactly the archive
        // case (`escape/outside`). Walk the existing prefixes under the base and
        // reject any symlink: a write must never be redirected through one.
        var prefix = base
        for part in parts {
            prefix.appendPathComponent(String(part))
            if (try? prefix.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { // try? ok: a missing prefix is not a symlink
                throw ValidationError.symbolicLink(relativePath)
            }
        }

        let destination = base.appendingPathComponent(relativePath).standardizedFileURL
        // URL.pathComponents can retain a terminal directory marker on Darwin.
        // Ignore separators consistently on BOTH sides (Payload/ is a directory,
        // not a traversal), while preserving strict component boundaries.
        let baseComponents = base.path.split(separator: "/", omittingEmptySubsequences: true)
        let destinationComponents = destination.path.split(separator: "/", omittingEmptySubsequences: true)
        guard destinationComponents.count > baseComponents.count,
              destinationComponents.starts(with: baseComponents) else {
            throw ValidationError.traversalPath(relativePath)
        }
    }

}
