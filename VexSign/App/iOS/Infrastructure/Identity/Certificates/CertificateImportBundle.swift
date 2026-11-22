//
//  CertificateImportBundle.swift
//  VexSign
//
//  Resolves the files a certificate import needs from what the user chose.
//
//  Until now the New Certificate screen demanded two separate picks: one `.p12`
//  and one `.mobileprovision`. Every source that hands out a certificate — a
//  shared `.zip`, a folder from Files, an extracted archive — arrives as one
//  thing holding both, so the screen was unusable for the most common real
//  workflow and reported it as a password problem. This resolves such a bundle
//  into the pair without changing what the importer accepts or trusts: the same
//  files are read, validated and staged, and the password is still required.
//

import Foundation
import NimbleExtensions

enum CertificateImportBundle {
    /// The two files one import needs, plus whether `p12` came from inside a
    /// container that the caller is responsible for cleaning up.
    struct Resolved {
        let key: URL
        let profile: URL
        /// Directory holding extracted copies, when the input was an archive or a
        /// folder. The caller removes it after the import finishes or fails.
        let staging: URL?
    }

    /// Type of one file inside the bundle: the password-protected private key.
    static let keyExtensions: Set<String> = ["p12", "pfx"]
    /// Provisioning profiles, including the older `.provisionprofile` spelling.
    static let profileExtensions: Set<String> = ["mobileprovision", "provisionprofile"]
    /// What a bundle picker offers: either file on its own, or a container of both.
    static let pickerExtensions = Array(keyExtensions) + Array(profileExtensions) + ["zip"]

    enum Problem: LocalizedError, Equatable {
        case unreadable
        /// The container was recognized but held no `.p12`.
        case missingKey
        case missingProfile
        /// Two different candidates of the same role: picking one silently could
        /// import the wrong identity, so the choice is refused and explained.
        case ambiguous(Role)
        case archiveUnreadable
        /// Which role was ambiguous. A localized value would be formatted into the
        /// message, so the role is a type and the sentence is chosen here.
        enum Role: Equatable { case key, profile, file }

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return .localized("The selected file could not be read. Choose the certificate file again.")
            case .missingKey:
                return .localized("No .p12 certificate was found. Choose the .p12 file, or a .zip that contains it together with its .mobileprovision profile.")
            case .missingProfile:
                return .localized("No .mobileprovision profile was found. A .p12 needs the profile that was issued with it; add both to the same .zip or folder and choose that.")
            case .ambiguous(.key):
                return .localized("The selection contains more than one .p12. Choose a container that holds exactly one certificate and one profile, or import each file separately.")
            case .ambiguous(.profile):
                return .localized("The selection contains more than one .mobileprovision. Choose a container that holds exactly one certificate and one profile, or import each file separately.")
            case .ambiguous(.file):
                return .localized("The selection contains too many files. Import a .zip or folder that holds one certificate and one profile.")
            case .archiveUnreadable:
                return .localized("This archive could not be opened. It may be damaged, or protected with a password.")
            }
        }
    }

    private static let manager = FileManager.default

    /// Resolves `url` into a key and a profile.
    ///
    /// A single file is returned as-is (the caller may still be missing the
    /// other role and says so). A directory or ZIP is searched, bounded, one
    /// level deep — real bundles put both files at the top or in one folder.
    static func resolve(_ url: URL) throws -> Resolved {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw Problem.unreadable }

        if isDirectory.boolValue {
            // A folder that already *is* a certificate directory: use its files.
            return try pair(inDirectory: url, staging: nil)
        }

        let ext = url.pathExtension.lowercased()
        if keyExtensions.contains(ext) {
            return Resolved(key: url, profile: url, staging: nil)
        }
        if profileExtensions.contains(ext) {
            return Resolved(key: url, profile: url, staging: nil)
        }
        guard PackageArchiveType.detect(at: url) == .zip else { throw Problem.unreadable }
        return try unzip(url)
    }

    /// True when `resolved` still needs its other half chosen by hand.
    static func missingRole(_ resolved: Resolved) -> Problem? {
        let key = keyExtensions.contains(resolved.key.pathExtension.lowercased())
        let profile = profileExtensions.contains(resolved.profile.pathExtension.lowercased())
        if !key && !profile { return .missingKey }
        return nil
    }

    // MARK: - Archive

    private static func unzip(_ archive: URL) throws -> Resolved {
        let staging = manager.temporaryDirectory
            .appendingPathComponent("VexSignCertificate_\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            // The same validator every other extractor uses: absolute paths,
            // traversal, symlinks and expansion bombs are refused before a byte
            // is written.
            try ArchiveSafetyValidator.validate(archive, destination: staging)
            try IPAExtractor.extract(archive, to: staging)
        } catch is CancellationError {
            try? manager.removeItem(at: staging) // try? ok: nothing was imported; cleanup is best effort
            throw CancellationError()
        } catch {
            try? manager.removeItem(at: staging) // try? ok: cleanup after a rejected archive
            throw Problem.archiveUnreadable
        }
        do {
            let resolved = try pair(inDirectory: staging, staging: staging)
            guard missingRole(resolved) == nil else { throw Problem.missingProfile }
            return resolved
        } catch {
            try? manager.removeItem(at: staging) // try? ok: rejected bundle leaves no temporary directory
            throw error
        }
    }

    // MARK: - Directory scan

    /// Finds exactly one key and one profile in `directory`, looking at the top
    /// level and one level down. Bounded and non-recursive so a giant folder
    /// cannot turn an import into a filesystem walk.
    private static func pair(inDirectory directory: URL, staging: URL?) throws -> Resolved {
        var keys: [URL] = []
        var profiles: [URL] = []
        var scanned = 0

        func classify(_ file: URL) {
            switch file.pathExtension.lowercased() {
            case let ext where keyExtensions.contains(ext): keys.append(file)
            case let ext where profileExtensions.contains(ext): profiles.append(file)
            default: break
            }
        }

        func children(of parent: URL) -> [URL] {
            (try? manager.contentsOfDirectory(  // try? ok: an unreadable child directory is simply not searched
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        for entry in children(of: directory).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            scanned += 1
            guard scanned <= 512 else { throw Problem.ambiguous(.file) }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) // try? ok: unreadable entry is skipped
            // Never follow a link out of the staging directory.
            guard values?.isSymbolicLink != true else { continue }
            if values?.isDirectory == true {
                for nested in children(of: entry).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    scanned += 1
                    guard scanned <= 512 else { throw Problem.ambiguous(.file) }
                    let nestedValues = try? nested.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) // try? ok: unreadable entry is skipped
                    guard nestedValues?.isSymbolicLink != true, nestedValues?.isDirectory != true else { continue }
                    classify(nested)
                }
            } else {
                classify(entry)
            }
        }

        switch (keys.count, profiles.count) {
        case (0, _): throw Problem.missingKey
        case (_, 0) where !keys.isEmpty: throw Problem.missingProfile
        case (1, 1): return Resolved(key: keys[0], profile: profiles[0], staging: staging)
        case (let keyCount, _) where keyCount > 1: throw Problem.ambiguous(.key)
        default: throw Problem.ambiguous(.profile)
        }
    }
}
