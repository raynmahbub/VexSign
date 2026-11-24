import Foundation
import OSLog

/// Tracks post-commit Keychain and filesystem deletions that failed after a certificate row
/// was removed from Core Data (or after a rolled-back import wrote a Keychain item).
///
/// Entries survive app relaunch, protect against UUID reuse while unresolved, and retry
/// whenever the app launches or protected data becomes available.
struct CertificateDeletionJournal: Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let uuid: String
        let keychainAccount: String
        let directoryPath: String?
        var pendingKeychainDeletion: Bool
        var pendingFilesystemDeletion: Bool
        var attempts: Int
        var lastError: String?
        let createdAt: Date
        var updatedAt: Date

        var id: String { uuid.uppercased() }
        var isResolved: Bool { !pendingKeychainDeletion && !pendingFilesystemDeletion }
    }

    struct RecoveryReport: Equatable, Sendable {
        var resolvedCount: Int
        var deferredCount: Int
        var unresolved: [Entry]

        static let empty = RecoveryReport(resolvedCount: 0, deferredCount: 0, unresolved: [])
    }

    let root: URL

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PendingCertificateCleanup", isDirectory: true)
    }

    static var defaultJournal: CertificateDeletionJournal {
        CertificateDeletionJournal(root: defaultDirectory)
    }

    func record(_ entry: Entry) throws {
        try validate(entry)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entry)
        guard data.count <= 16 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        var url = entryURL(for: entry.uuid)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func remove(uuid: String) throws {
        let url = entryURL(for: uuid)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func hasPendingEntry(forUUID uuid: String) throws -> Bool {
        let normalized = uuid.uppercased()
        return try loadAll().contains { $0.uuid.uppercased() == normalized && !$0.isResolved }
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
                      (values.fileSize ?? Int.max) <= 16 * 1024 else {
                    continue
                }
                let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
                guard file.lastPathComponent.lowercased() == "\(entry.uuid.lowercased()).json" else { continue }
                try validate(entry)
                entries.append(entry)
            } catch {
                let redacted = LogRedaction.redact(error.localizedDescription)
                Logger.misc.warning(
                    "Skipping unreadable certificate cleanup journal entry \(file.lastPathComponent, privacy: .public): \(redacted, privacy: .public)"
                )
            }
        }
        return entries.sorted { $0.updatedAt > $1.updatedAt }
    }

    func unresolvedEntries() -> [Entry] {
        do {
            return try loadAll().filter { !$0.isResolved }
        } catch {
            return []
        }
    }

    @discardableResult
    func recoverPending(
        identityExists: (String) throws -> Bool,
        deleteSecret: (String) throws -> Void = { try SecureSecretStore.delete($0) },
        allowedDirectory: (URL) -> Bool = { Storage.allowedCertificateDeletionOriginal($0) },
        removeDirectory: (URL) throws -> Void = { directory in
            let root = directory.deletingLastPathComponent()
            _ = try CleanupRemovalPolicy.remove(directory, beneath: root)
        },
        now: Date = Date()
    ) -> RecoveryReport {
        let entries: [Entry]
        do {
            entries = try loadAll()
        } catch {
            let redacted = LogRedaction.redact(error.localizedDescription)
            Logger.misc.error("Could not load certificate cleanup journal: \(redacted, privacy: .public)")
            return .empty
        }

        var report = RecoveryReport.empty
        for var entry in entries {
            let existsInStore: Bool
            do {
                existsInStore = try identityExists(entry.uuid)
            } catch {
                let redacted = LogRedaction.redact(error.localizedDescription)
                Logger.misc.warning(
                    "Deferring certificate cleanup for \(entry.uuid, privacy: .public); store unreadable: \(redacted, privacy: .public)"
                )
                report.deferredCount += 1
                report.unresolved.append(entry)
                continue
            }

            if existsInStore {
                // Never delete credentials or files while a live certificate row owns this UUID.
                Logger.misc.warning(
                    "Deferring certificate cleanup for \(entry.uuid, privacy: .public); active certificate row exists."
                )
                report.deferredCount += 1
                report.unresolved.append(entry)
                continue
            }

            var errors: [String] = []

            if entry.pendingKeychainDeletion {
                do {
                    try deleteSecret(entry.keychainAccount)
                    entry.pendingKeychainDeletion = false
                } catch {
                    let redacted = LogRedaction.redact(error.localizedDescription)
                    errors.append("keychain: \(redacted)")
                }
            }

            if entry.pendingFilesystemDeletion {
                if let path = entry.directoryPath {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    if allowedDirectory(directory) {
                        do {
                            try removeDirectory(directory)
                            entry.pendingFilesystemDeletion = false
                        } catch {
                            let redacted = LogRedaction.redact(error.localizedDescription)
                            errors.append("filesystem: \(redacted)")
                        }
                    } else {
                        errors.append("filesystem: target directory failed containment validation")
                    }
                } else {
                    entry.pendingFilesystemDeletion = false
                }
            }

            if entry.isResolved {
                do {
                    try remove(uuid: entry.uuid)
                    report.resolvedCount += 1
                } catch {
                    let redacted = LogRedaction.redact(error.localizedDescription)
                    Logger.misc.warning(
                        "Failed removing resolved certificate cleanup journal \(entry.uuid, privacy: .public): \(redacted, privacy: .public)"
                    )
                }
            } else {
                entry.attempts += 1
                entry.lastError = errors.joined(separator: "; ")
                entry.updatedAt = now
                do {
                    try record(entry)
                } catch {
                    let redacted = LogRedaction.redact(error.localizedDescription)
                    Logger.misc.error(
                        "Failed updating certificate cleanup journal \(entry.uuid, privacy: .public): \(redacted, privacy: .public)"
                    )
                }
                report.unresolved.append(entry)
            }
        }
        return report
    }

    private func entryURL(for uuid: String) -> URL {
        root.appendingPathComponent("\(uuid.uppercased()).json")
    }

    private func validate(_ entry: Entry) throws {
        guard UUID(uuidString: entry.uuid) != nil,
              entry.keychainAccount == "certificate.password.\(entry.uuid)" else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
