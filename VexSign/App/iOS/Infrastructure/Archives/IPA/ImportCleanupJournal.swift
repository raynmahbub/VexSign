import Foundation
import OSLog

/// Persists in-flight and pending-cleanup IPA imports so interrupted imports or failed
/// removals are retried on launch without ever deleting source IPAs or committed library rows.
struct ImportCleanupJournal: Sendable {
    enum Lifecycle: String, Codable, Equatable, Sendable {
        case copying
        case extracting
        case validating
        case moving
        case registering
        case committed
        case cleanupPending
        case failed
        case cancelled
    }

    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let fileName: String
        let workDirectoryName: String
        let libraryUUID: String
        var state: Lifecycle
        var cleanupAttempts: Int
        var lastCleanupError: String?
        let createdAt: Date
        var updatedAt: Date
    }

    struct RecoveryReport: Equatable, Sendable {
        var cleanedWorkDirectories: Int
        var cleanedUncommittedArtifacts: Int
        var preservedCommittedArtifacts: Int
        var deferredActiveOrUnavailable: Int
        var unresolved: [Entry]

        static let empty = RecoveryReport(
            cleanedWorkDirectories: 0,
            cleanedUncommittedArtifacts: 0,
            preservedCommittedArtifacts: 0,
            deferredActiveOrUnavailable: 0,
            unresolved: []
        )
    }

    struct CleanupError: LocalizedError {
        let importID: String
        let fileName: String
        let underlying: Error

        var errorDescription: String? {
            let detail = LogRedaction.redact(underlying.localizedDescription)
            return "Import cleanup for \(fileName) (\(importID)) is pending retry: \(detail)"
        }
    }

    let root: URL

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PendingImportCleanup", isDirectory: true)
    }

    static var defaultJournal: ImportCleanupJournal {
        ImportCleanupJournal(root: defaultDirectory)
    }

    func record(_ entry: Entry) throws {
        try validate(entry)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entry)
        guard data.count <= 32 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        var fileURL = entryURL(for: entry.id)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try fileURL.setResourceValues(values)
    }

    func update(
        id: String,
        state: Lifecycle,
        cleanupError: String? = nil,
        incrementAttempts: Bool = false,
        now: Date = Date()
    ) throws {
        guard var entry = try loadEntry(id: id) else { return }
        entry.state = state
        if incrementAttempts {
            entry.cleanupAttempts += 1
        }
        if let cleanupError {
            entry.lastCleanupError = LogRedaction.redact(cleanupError)
        } else if state == .committed {
            entry.lastCleanupError = nil
        }
        entry.updatedAt = now
        try record(entry)
    }

    func remove(id: String) throws {
        let url = entryURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func loadAll() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard files.count <= 1000 else { throw CocoaError(.fileReadCorruptFile) }
        var entries: [Entry] = []
        for file in files where file.pathExtension == "json" {
            do {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      (values.fileSize ?? Int.max) <= 32 * 1024 else {
                    continue
                }
                let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
                guard file.lastPathComponent == "\(entry.id).json" else { continue }
                try validate(entry)
                entries.append(entry)
            } catch {
                let redacted = LogRedaction.redact(error.localizedDescription)
                Logger.misc.warning(
                    "Skipping unreadable import cleanup journal entry \(file.lastPathComponent, privacy: .public): \(redacted, privacy: .public)"
                )
            }
        }
        return entries.sorted { $0.updatedAt > $1.updatedAt }
    }

    func unresolvedEntries() -> [Entry] {
        do {
            return try loadAll().filter { $0.state == .cleanupPending || $0.lastCleanupError != nil }
        } catch {
            return []
        }
    }

    @discardableResult
    func recoverPending(
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        unsignedRoot: URL = FileManager.default.unsigned,
        rowExists: (String) throws -> Bool,
        isOperationActive: (String) -> Bool = { AppOperationRegistry.shared.knowsProduction(of: $0) },
        removeDirectory: (URL, URL) throws -> Bool = { target, allowedRoot in
            try CleanupRemovalPolicy.remove(target, beneath: allowedRoot)
        },
        now: Date = Date()
    ) -> RecoveryReport {
        let entries: [Entry]
        do {
            entries = try loadAll()
        } catch {
            let redacted = LogRedaction.redact(error.localizedDescription)
            Logger.misc.error("Could not load import cleanup journal: \(redacted, privacy: .public)")
            return .empty
        }

        var report = RecoveryReport.empty
        for var entry in entries {
            if isOperationActive(entry.libraryUUID) {
                report.deferredActiveOrUnavailable += 1
                continue
            }

            let committedInStore: Bool
            do {
                committedInStore = try rowExists(entry.libraryUUID)
            } catch {
                // Never delete library artifacts when the persistent store cannot be queried.
                let redacted = LogRedaction.redact(error.localizedDescription)
                Logger.misc.warning(
                    "Deferring import cleanup recovery for \(entry.id, privacy: .public); store unavailable: \(redacted, privacy: .public)"
                )
                report.deferredActiveOrUnavailable += 1
                continue
            }

            var errors: [String] = []

            let workDir = temporaryRoot.appendingPathComponent(entry.workDirectoryName, isDirectory: true)
            do {
                if try removeDirectory(workDir, temporaryRoot) {
                    report.cleanedWorkDirectories += 1
                }
            } catch {
                errors.append(LogRedaction.redact(error.localizedDescription))
            }

            let artifactDir = unsignedRoot.appendingPathComponent(entry.libraryUUID, isDirectory: true)
            if committedInStore || entry.state == .committed {
                report.preservedCommittedArtifacts += 1
            } else {
                do {
                    if try removeDirectory(artifactDir, unsignedRoot) {
                        report.cleanedUncommittedArtifacts += 1
                    }
                } catch {
                    errors.append(LogRedaction.redact(error.localizedDescription))
                }
            }

            if errors.isEmpty {
                do {
                    try remove(id: entry.id)
                } catch {
                    let redacted = LogRedaction.redact(error.localizedDescription)
                    Logger.misc.warning(
                        "Failed removing resolved import journal \(entry.id, privacy: .public): \(redacted, privacy: .public)"
                    )
                }
            } else {
                entry.state = .cleanupPending
                entry.cleanupAttempts += 1
                entry.lastCleanupError = errors.joined(separator: "; ")
                entry.updatedAt = now
                do {
                    try record(entry)
                } catch {
                    let redacted = LogRedaction.redact(error.localizedDescription)
                    Logger.misc.error(
                        "Failed persisting retry state for import journal \(entry.id, privacy: .public): \(redacted, privacy: .public)"
                    )
                }
                report.unresolved.append(entry)
            }
        }
        return report
    }

    @discardableResult
    static func recoverOnLaunch() -> RecoveryReport {
        defaultJournal.recoverPending { uuid in
            try Storage.shared.containsCommittedImported(uuid: uuid)
        }
    }

    private func loadEntry(id: String) throws -> Entry? {
        let url = entryURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
        try validate(entry)
        return entry
    }

    private func entryURL(for id: String) -> URL {
        root.appendingPathComponent("\(id).json")
    }

    private func validate(_ entry: Entry) throws {
        guard UUID(uuidString: entry.id) != nil,
              UUID(uuidString: entry.libraryUUID) != nil,
              entry.fileName.utf8.count <= 1024,
              isSafeComponent(entry.workDirectoryName) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && name.utf8.count <= 255
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("\0")
    }
}
