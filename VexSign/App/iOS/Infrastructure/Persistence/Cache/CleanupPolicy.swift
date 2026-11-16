//
//  CleanupPolicy.swift
//  VexSign
//
//  What a cleanup pass may remove: which storage areas it clears while an operation is still
//  running, and which signed copies the "Keep only the newest signed copy" rule gives up.
//
//  Both are decisions about files the user may still want, so they are kept here as plain rules
//  that can be tested without the storage layer. `CleanupManager` and `StorageRules` carry them
//  out.
//

import Foundation

// MARK: - Storage areas

enum PendingInstallCleanupPolicy {
    /// Keep every staged identifier whose deletion did not commit, unless an authoritative row
    /// lookup confirmed that the target is already absent. The order is stable and duplicate
    /// identifiers from older defaults values are collapsed so a later flush remains idempotent.
    static func remaining(
        _ staged: [String],
        afterDeleting deleted: Set<String>,
        confirmedMissing: Set<String> = []
    ) -> [String] {
        var seen = Set<String>()
        return staged.filter {
            !deleted.contains($0) && !confirmedMissing.contains($0) && seen.insert($0).inserted
        }
    }
}

/// Narrow path policy for automatic deletion of downloaded IPA files. A prefix match is not
/// containment (`VexSignDownloads-old` is a sibling), and checking only the lexical URL lets a
/// symlink inside staging point at a library artifact. Require a regular file strictly below the
/// owned staging directory, itself strictly below the temporary root, after resolving links.
enum CleanupArtifactPolicy {
    static func isSafeDownloadedArtifact(
        _ candidate: URL,
        stagingRoot: URL,
        temporaryRoot: URL,
        protectedRoots: [URL],
        fileManager: FileManager = .default
    ) -> Bool {
        guard candidate.isFileURL, stagingRoot.isFileURL, temporaryRoot.isFileURL else { return false }

        let lexicalCandidate = candidate.standardizedFileURL
        let lexicalStaging = stagingRoot.standardizedFileURL
        let lexicalTemporary = temporaryRoot.standardizedFileURL
        guard isStrictlyWithin(lexicalStaging, root: lexicalTemporary),
              isStrictlyWithin(lexicalCandidate, root: lexicalStaging) else { return false }
        let stagingValues: URLResourceValues
        let candidateValues: URLResourceValues
        do {
            stagingValues = try lexicalStaging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            candidateValues = try lexicalCandidate.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            return false
        }
        guard stagingValues.isDirectory == true, stagingValues.isSymbolicLink != true,
              candidateValues.isRegularFile == true, candidateValues.isDirectory != true,
              candidateValues.isSymbolicLink != true,
              fileManager.fileExists(atPath: lexicalCandidate.path) else { return false }

        let resolvedTemporary = lexicalTemporary.resolvingSymlinksInPath().standardizedFileURL
        let resolvedStaging = lexicalStaging.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = lexicalCandidate.resolvingSymlinksInPath().standardizedFileURL
        guard isStrictlyWithin(resolvedStaging, root: resolvedTemporary),
              isStrictlyWithin(resolvedCandidate, root: resolvedStaging) else { return false }

        for root in protectedRoots where root.isFileURL {
            let protected = root.resolvingSymlinksInPath().standardizedFileURL
            if contains(resolvedCandidate, within: protected) || contains(protected, within: resolvedCandidate) {
                return false
            }
        }
        return true
    }

    static func isStrictlyWithin(_ item: URL, root: URL) -> Bool {
        let path = item.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path != rootPath && path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func contains(_ item: URL, within root: URL) -> Bool {
        let path = item.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

/// Component-aware, fail-closed removal for owned cleanup roots. Both lexical and resolved paths
/// must remain inside the authorized root, and neither the target nor root may be a symlink.
enum CleanupRemovalPolicy {
    enum Rejection: LocalizedError {
        case unsafeTarget

        var errorDescription: String? { "The cleanup target failed its path-safety check." }
    }

    static func isDirectoryRoot(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        } catch {
            return false
        }
    }

    static func isSafeDirectory(_ candidate: URL, beneath root: URL) -> Bool {
        guard isSafeTarget(candidate, beneath: root) else { return false }
        do {
            return try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        } catch {
            return false
        }
    }

    static func isSafeTarget(
        _ candidate: URL,
        beneath root: URL,
        allowRoot: Bool = false,
        protectedRoots: [URL] = []
    ) -> Bool {
        guard candidate.isFileURL, root.isFileURL else { return false }
        let item = candidate.standardizedFileURL
        let base = root.standardizedFileURL
        let samePath = item.path == base.path
        guard (samePath && allowRoot) || (!samePath && isStrictlyWithin(item, root: base)) else { return false }
        do {
            let itemValues = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard itemValues.isSymbolicLink != true else { return false }
            if !samePath {
                let baseValues = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard baseValues.isDirectory == true, baseValues.isSymbolicLink != true else { return false }
                var ancestor = item.deletingLastPathComponent()
                while ancestor.standardizedFileURL.path != base.path {
                    guard isStrictlyWithin(ancestor, root: base) else { return false }
                    let ancestorValues = try ancestor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard ancestorValues.isDirectory == true, ancestorValues.isSymbolicLink != true else { return false }
                    let parent = ancestor.deletingLastPathComponent()
                    guard parent.path != ancestor.path else { return false }
                    ancestor = parent
                }
            }
        } catch {
            return false
        }

        let resolvedItem = item.resolvingSymlinksInPath().standardizedFileURL
        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
        guard (resolvedItem.path == resolvedBase.path && allowRoot)
                || (resolvedItem.path != resolvedBase.path && isStrictlyWithin(resolvedItem, root: resolvedBase)) else {
            return false
        }
        for protectedRoot in protectedRoots where protectedRoot.isFileURL {
            let protected = protectedRoot.resolvingSymlinksInPath().standardizedFileURL
            if contains(resolvedItem, within: protected) || contains(protected, within: resolvedItem) {
                return false
            }
        }
        return true
    }

    /// Measures the bytes that removing an item can actually reclaim. Symbolic links are not
    /// followed or counted, even when nested inside an owned directory being deleted.
    static func allocatedSizeWithoutFollowingSymlinks(at url: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey, .fileSizeKey
        ]
        func regularFileSize(_ values: URLResourceValues) -> Int64 {
            Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        do {
            let rootValues = try url.resourceValues(forKeys: keys)
            guard rootValues.isSymbolicLink != true else { return 0 }
            guard rootValues.isDirectory == true else { return regularFileSize(rootValues) }
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
            var total: Int64 = 0
            while let child = enumerator.nextObject() as? URL {
                do {
                    let values = try child.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true {
                        enumerator.skipDescendants()
                    } else if values.isDirectory != true {
                        total += regularFileSize(values)
                    }
                } catch {
                    enumerator.skipDescendants()
                }
            }
            return total
        } catch {
            return 0
        }
    }

    /// Removes one item. `nil` means it was already absent; a byte count (including zero) means
    /// `removeItem` succeeded. Errors are deliberately propagated so callers cannot report a
    /// failed deletion as reclaimed storage.
    static func remove(
        _ candidate: URL,
        beneath root: URL,
        allowRoot: Bool = false,
        protectedRoots: [URL] = [],
        fileManager: FileManager = .default
    ) throws -> Int64? {
        guard candidate.isFileURL, root.isFileURL else { throw Rejection.unsafeTarget }
        let item = candidate.standardizedFileURL
        let itemValues: URLResourceValues
        do {
            itemValues = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard itemValues.isSymbolicLink != true else { throw Rejection.unsafeTarget }
        guard fileManager.fileExists(atPath: item.path) else { return nil }
        guard isSafeTarget(item, beneath: root, allowRoot: allowRoot, protectedRoots: protectedRoots) else {
            throw Rejection.unsafeTarget
        }

        let size = allocatedSizeWithoutFollowingSymlinks(at: item, fileManager: fileManager)
        try fileManager.removeItem(at: item)
        return size
    }

    static func isStrictlyWithin(_ item: URL, root: URL) -> Bool {
        let path = item.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path != rootPath && path.hasPrefix(prefix)
    }

    private static func contains(_ item: URL, within root: URL) -> Bool {
        let path = item.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path == rootPath || path.hasPrefix(prefix)
    }
}

enum CleanupPassPolicy {
	/// Storage areas a pass leaves alone while an operation is running.
	///
	/// The temporary directory holds the work directory of every sign in flight and the archive
	/// a running install is handing to iOS. Clearing it because one operation had finished took
	/// those files away from every other operation, which then stopped part-way.
	///
	/// A leftover is a folder in the library that no row accounts for. A copy that is being
	/// produced is exactly that between the moment its bundle is moved into the library and the
	/// moment its row is committed, so a pass that removed leftovers in that window deleted a
	/// bundle that was about to be registered.
	static let deferredWhileOperating: [StorageCategory] = [.temporary, .leftovers]

	struct Plan: Equatable {
		/// Cleared now, in the order they were asked for.
		var clear: [StorageCategory]
		/// Asked for, and left for a later pass because something is running.
		var deferred: [StorageCategory]
	}

	/// Splits what was asked for into what is cleared now and what waits.
	///
	/// Nothing is ever added: a category that was not asked for is in neither list. What waits is
	/// picked up by the next pass that finds nothing running, and by the next launch.
	static func plan(_ requested: [StorageCategory], operationsActive: Bool) -> Plan {
		guard operationsActive else {
			return Plan(clear: requested, deferred: [])
		}
		return Plan(
			clear: requested.filter { !deferredWhileOperating.contains($0) },
			deferred: requested.filter { deferredWhileOperating.contains($0) }
		)
	}
}

// MARK: - Duplicate signed copies

/// The "Keep only the newest signed copy" rule.
enum SignedCopyRetention {
	/// What the rule reads of one signed copy.
	struct Copy: Equatable {
		let uuid: String
		/// What makes two copies the same app: the bundle identifier, or the name without one.
		let app: String
		let version: String?
		/// When the copy was added to the library.
		let date: Date?
	}

	/// The copies the rule removes: for every app with several signed copies, all but one.
	///
	/// The copy that is kept has the highest version. Among copies of the same version it is the
	/// one added last. A re-sign produces a copy with the same version as the one it was started
	/// from, and the rule used to compare versions only, which left the choice between those two
	/// to the order the rows happened to be fetched in. It could keep the older copy and delete
	/// the one that had just been signed.
	///
	/// The result is in a stable order, so the same library always gives the same answer.
	static func surplus(among copies: [Copy]) -> [Copy] {
		var seen = Set<String>()
		let distinct = copies.filter { seen.insert($0.uuid).inserted }
		let groups = Dictionary(grouping: distinct, by: \.app)

		return groups.keys.sorted().flatMap { app -> [Copy] in
			let ranked = (groups[app] ?? []).sorted { isKept($0, before: $1) }
			return Array(ranked.dropFirst())
		}
	}

	/// True when `first` is the copy to keep out of the two.
	static func isKept(_ first: Copy, before second: Copy) -> Bool {
		let firstVersion = versionKey(first.version)
		let secondVersion = versionKey(second.version)
		if firstVersion != secondVersion {
			return secondVersion.lexicographicallyPrecedes(firstVersion)
		}

		let firstDate = first.date ?? .distantPast
		let secondDate = second.date ?? .distantPast
		if firstDate != secondDate {
			return firstDate > secondDate
		}

		// Same version, same moment: any fixed order will do, as long as it is always the same.
		return first.uuid < second.uuid
	}

	/// The numeric components of a version, without trailing zeros, so "1.2" and "1.2.0" are the
	/// same version and the date decides between them. A component that is not a number is
	/// skipped, as before; a copy with no readable version sorts below every other.
	static func versionKey(_ version: String?) -> [Int] {
		guard let version else { return [] }
		var parts = version.split(separator: ".").compactMap { Int($0) }
		while parts.last == 0 { parts.removeLast() }
		return parts
	}
}
