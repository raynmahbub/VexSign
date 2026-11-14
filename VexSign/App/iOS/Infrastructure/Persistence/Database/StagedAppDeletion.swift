import Foundation

/// A manifest is durable before any move. Database success is the commit point;
/// cleanup failure leaves quarantine for recovery, never an untracked orphan.
struct StagedAppDeletion {
    struct Entry: Codable {
        let original: URL
        let objectURI: URL
        let slot: String
    }
    let directory: URL
    let entries: [Entry]
    private var manifest: URL { directory.appendingPathComponent("manifest.json") }

    init(root: URL, originals: [(URL, URL)]) throws {
        guard !originals.isEmpty, originals.count <= 10_000,
              Set(originals.map { $0.0.standardizedFileURL.path.lowercased() }).count == originals.count,
              originals.allSatisfy({ !root.standardizedFileURL.path.hasPrefix($0.0.standardizedFileURL.path + "/") && root.standardizedFileURL != $0.0.standardizedFileURL }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        entries = originals.enumerated().map { .init(original: $0.element.0, objectURI: $0.element.1, slot: String($0.offset)) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try JSONEncoder().encode(entries).write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    init(directory: URL) throws {
        self.directory = directory
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let file = directory.appendingPathComponent("manifest.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard values.isDirectory == true, values.isSymbolicLink != true,
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value ?? Int64.max <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
        guard !entries.isEmpty, entries.count <= 10_000 else { throw CocoaError(.fileReadTooLarge) }
    }

    func stage(move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        for entry in entries where FileManager.default.fileExists(atPath: entry.original.path) {
            guard (try entry.original.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try move(entry.original, directory.appendingPathComponent(entry.slot))
        }
    }

    /// Check every row before modifying recovery files. An unavailable database
    /// must throw; it must never be interpreted as a deleted row.
    ///
    /// Certificate undo may have restored files just before a failed/interrupted
    /// row insertion. Opting into `removingUnownedOriginals` keeps those bytes
    /// under this journal's cleanup ownership. That caller MUST also consider
    /// replacement rows owning the same original path, not only the old row ID.
    /// Ordinary app-deletion recovery retains its existing staged-only policy.
    func recover(rowExists: (URL) throws -> Bool,
                 allowedOriginal: (URL) -> Bool,
                 retainingManifest: Bool = false,
                 removingUnownedOriginals: Bool = false,
                 remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        guard Set(entries.map(\.slot)).count == entries.count,
              Set(entries.map { $0.original.standardizedFileURL.path.lowercased() }).count == entries.count else { throw CocoaError(.fileReadCorruptFile) }
        let decisions = try entries.map { entry -> (Entry, Bool) in
            guard allowedOriginal(entry.original), !entry.slot.isEmpty,
                  entry.slot.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = Int(entry.slot), number >= 0, number < entries.count, entry.slot == String(number),
                  !entry.slot.contains("/"), !entry.slot.contains("..") else { throw CocoaError(.fileReadCorruptFile) }
            return (entry, try rowExists(entry.objectURI))
        }
        for (entry, exists) in decisions {
            let staged = directory.appendingPathComponent(entry.slot)
            if FileManager.default.fileExists(atPath: staged.path),
               (try staged.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw CocoaError(.fileReadCorruptFile) }
            if exists {
                guard FileManager.default.fileExists(atPath: staged.path) else { continue }
                // A newer original is never overwritten; retain the manifest.
                guard !FileManager.default.fileExists(atPath: entry.original.path) else { throw CocoaError(.fileWriteFileExists) }
                try FileManager.default.moveItem(at: staged, to: entry.original)
            } else {
                if FileManager.default.fileExists(atPath: staged.path) { try remove(staged) }
                if removingUnownedOriginals, FileManager.default.fileExists(atPath: entry.original.path) {
                    try remove(entry.original)
                }
            }
        }
        // Certificate undo restores files before inserting its row. Retain the
        // same journal until that transaction commits, so a failed insert can
        // re-stage the files under the original erasure/recovery ownership.
        if !retainingManifest { try remove(directory) }
    }
}
