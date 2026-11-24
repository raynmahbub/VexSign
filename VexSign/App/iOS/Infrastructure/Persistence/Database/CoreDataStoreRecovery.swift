//
//  CoreDataStoreRecovery.swift
//  VexSign
//
//  Non-destructive transactional quarantine recovery for unreadable SQLite Core Data stores.
//

import Foundation
import OSLog

/// Moves unreadable Core Data SQLite files out of the way into `QuarantinedStores/`
/// so a fresh store can open without deleting signed/unsigned app bundles or certificates.
///
/// Sidecar moves (`.sqlite`, `.sqlite-wal`, `.sqlite-shm`) are tracked as a unit:
/// if moving any file fails, all previously moved files are restored to their original paths
/// before the error is surfaced.
enum CoreDataStoreRecovery {
    enum QuarantineError: LocalizedError {
        case moveFailed(fileName: String, underlying: Error, rollbackFailures: [String])

        var errorDescription: String? {
            switch self {
            case let .moveFailed(fileName, underlying, rollbackFailures):
                let detail = LogRedaction.redact(underlying.localizedDescription)
                if rollbackFailures.isEmpty {
                    return "Could not move \(fileName) into quarantine (\(detail)); earlier moves were rolled back."
                }
                let list = rollbackFailures.joined(separator: ", ")
                return "Could not move \(fileName) into quarantine (\(detail)); rollback failed for: \(list)."
            }
        }
    }

    struct Notice: Equatable, Sendable {
        let quarantineFolderName: String
        let recoveredAt: Date
        let summary: String
        let quarantineDirectory: URL?
        let isPersistentStorageUnavailable: Bool

        init(
            quarantineFolderName: String,
            recoveredAt: Date,
            summary: String,
            quarantineDirectory: URL? = nil,
            isPersistentStorageUnavailable: Bool = false
        ) {
            self.quarantineFolderName = quarantineFolderName
            self.recoveredAt = recoveredAt
            self.summary = summary
            self.quarantineDirectory = quarantineDirectory
            self.isPersistentStorageUnavailable = isPersistentStorageUnavailable
        }
    }

    struct Outcome: Equatable, Sendable {
        let movedFiles: [URL]
        let quarantineDirectory: URL
        let notice: Notice
    }

    struct QuarantinedStore: Identifiable, Equatable, Sendable {
        let folderName: String
        let directoryURL: URL
        let files: [URL]

        var id: String { folderName }
    }

    static func quarantineRoot(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("QuarantinedStores", isDirectory: true)
    }

    static func quarantineStore(
        at storeURL: URL?,
        quarantineRoot: URL? = nil,
        reason: String,
        fileManager: FileManager = .default,
        now: Date = Date(),
        moveItem: ((URL, URL) throws -> Void)? = nil,
        rollbackMove: ((URL, URL) throws -> Void)? = nil
    ) throws -> Outcome? {
        guard let storeURL else { return nil }

        let base = storeURL.deletingPathExtension()
        let sidecars = [
            base.appendingPathExtension("sqlite"),
            base.appendingPathExtension("sqlite-wal"),
            base.appendingPathExtension("sqlite-shm")
        ]
        let existing = sidecars.filter { fileManager.fileExists(atPath: $0.path) }

        let root = quarantineRoot ?? self.quarantineRoot(for: storeURL)
        let stamp = _timestamp(from: now)
        let folderName = "VexSign-\(stamp)-\(UUID().uuidString.prefix(8))"
        let destinationDir = root.appendingPathComponent(folderName, isDirectory: true)

        let performMove: (URL, URL) throws -> Void = moveItem ?? { source, destination in
            try fileManager.moveItem(at: source, to: destination)
        }
        let performRollback: (URL, URL) throws -> Void = rollbackMove ?? { source, destination in
            try fileManager.moveItem(at: source, to: destination)
        }

        var movedPairs: [(source: URL, destination: URL)] = []
        if !existing.isEmpty {
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            for source in existing {
                let destination = destinationDir.appendingPathComponent(source.lastPathComponent)
                do {
                    try performMove(source, destination)
                    movedPairs.append((source: source, destination: destination))
                } catch {
                    var rollbackFailures: [String] = []
                    for pair in movedPairs.reversed() {
                        do {
                            try performRollback(pair.destination, pair.source)
                        } catch let rollbackError {
                            rollbackFailures.append(pair.source.lastPathComponent)
                            let redacted = LogRedaction.redact(rollbackError.localizedDescription)
                            Logger.misc.fault(
                                "Quarantine rollback failed for \(pair.source.lastPathComponent, privacy: .public): \(redacted, privacy: .public)"
                            )
                        }
                    }
                    if rollbackFailures.isEmpty {
                        _removeEmptyDirectoryIfPossible(destinationDir, fileManager: fileManager)
                    }
                    throw QuarantineError.moveFailed(
                        fileName: source.lastPathComponent,
                        underlying: error,
                        rollbackFailures: rollbackFailures
                    )
                }
            }
        }

        let moved = movedPairs.map(\.destination)
        let notice = Notice(
            quarantineFolderName: folderName,
            recoveredAt: now,
            summary: LogRedaction.redact(reason),
            quarantineDirectory: existing.isEmpty ? nil : destinationDir,
            isPersistentStorageUnavailable: false
        )
        return Outcome(movedFiles: moved, quarantineDirectory: destinationDir, notice: notice)
    }

    static func listQuarantinedStores(
        in root: URL,
        fileManager: FileManager = .default
    ) -> [QuarantinedStore] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            let redacted = LogRedaction.redact(error.localizedDescription)
            Logger.misc.warning("Could not list quarantined stores: \(redacted, privacy: .public)")
            return []
        }

        var stores: [QuarantinedStore] = []
        for entry in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            do {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let contents = try fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
                let files = contents.filter { file in
                    do {
                        let fileValues = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        return fileValues.isRegularFile == true && fileValues.isSymbolicLink != true
                    } catch {
                        return false
                    }
                }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                stores.append(QuarantinedStore(folderName: entry.lastPathComponent, directoryURL: entry, files: files))
            } catch {
                continue
            }
        }
        return stores
    }

    /// Copies a quarantined store directory to a user-chosen or diagnostics export location
    /// without mutating or removing the quarantined originals.
    static func exportQuarantinedStore(
        _ store: QuarantinedStore,
        to destinationParent: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        let target = destinationParent.appendingPathComponent(store.folderName, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        for file in store.files {
            let copied = target.appendingPathComponent(file.lastPathComponent)
            try fileManager.copyItem(at: file, to: copied)
        }
        return target
    }

    private static func _removeEmptyDirectoryIfPossible(_ directory: URL, fileManager: FileManager) {
        do {
            let remaining = try fileManager.contentsOfDirectory(atPath: directory.path)
            if remaining.isEmpty {
                try fileManager.removeItem(at: directory)
            }
        } catch {
            let redacted = LogRedaction.redact(error.localizedDescription)
            Logger.misc.warning(
                "Could not remove empty quarantine folder after rollback: \(redacted, privacy: .public)"
            )
        }
    }

    private static func _timestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
