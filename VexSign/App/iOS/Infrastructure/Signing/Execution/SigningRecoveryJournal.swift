import Foundation
import OSLog

enum SigningRecoveryState: String, Codable, Equatable, Sendable {
    case preparing
    case copying
    case modifying
    case signing
    case verifying
    case moving
    case registering
    case committed
    case cleanupPending
    case failed
    case cancelled
}

struct SigningRecoveryJournal: Sendable {
    struct Record: Codable, Equatable, Identifiable, Sendable {
        let operationID: String
        let appName: String
        let sourceAppUUID: String?
        let workDirectoryName: String
        var state: SigningRecoveryState
        var createdWorkDirectory: Bool
        var createdSignedDirectory: Bool
        var committedToDatabase: Bool
        var cleanupAttempts: Int
        var lastError: String?
        let createdAt: Date
        var updatedAt: Date

        var id: String { operationID }
    }

    struct RecoveryReport: Equatable, Sendable {
        var cleanedWorkDirectories: Int
        var cleanedUncommittedSignedDirectories: Int
        var preservedCommittedSignedDirectories: Int
        var deferredCount: Int
        var corruptJournalCount: Int
        var unresolved: [Record]

        static let empty = RecoveryReport(
            cleanedWorkDirectories: 0,
            cleanedUncommittedSignedDirectories: 0,
            preservedCommittedSignedDirectories: 0,
            deferredCount: 0,
            corruptJournalCount: 0,
            unresolved: []
        )
    }

    let root: URL

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PendingSigningRecovery", isDirectory: true)
    }

    static var defaultJournal: SigningRecoveryJournal {
        SigningRecoveryJournal(root: defaultDirectory)
    }

    func save(_ record: Record) throws {
        try validate(record)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 32 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        var url = recordURL(for: record.operationID)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func update(
        operationID: String,
        state: SigningRecoveryState,
        createdWorkDirectory: Bool? = nil,
        createdSignedDirectory: Bool? = nil,
        committedToDatabase: Bool? = nil,
        error: String? = nil,
        incrementCleanupAttempts: Bool = false,
        now: Date = Date()
    ) throws {
        guard var record = try loadRecord(operationID: operationID) else { return }
        record.state = state
        if let createdWorkDirectory {
            record.createdWorkDirectory = createdWorkDirectory
        }
        if let createdSignedDirectory {
            record.createdSignedDirectory = createdSignedDirectory
        }
        if let committedToDatabase {
            record.committedToDatabase = committedToDatabase
        }
        if incrementCleanupAttempts {
            record.cleanupAttempts += 1
        }
        if let error {
            record.lastError = LogRedaction.redact(error)
        }
        record.updatedAt = now
        try save(record)
    }

    func remove(operationID: String) throws {
        let url = recordURL(for: operationID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func loadAll() throws -> (records: [Record], corruptCount: Int) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], 0) }
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard files.count <= 1000 else { throw CocoaError(.fileReadCorruptFile) }
        var records: [Record] = []
        var corruptCount = 0
        for file in files where file.pathExtension == "json" {
            do {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      (values.fileSize ?? Int.max) <= 32 * 1024 else {
                    corruptCount += 1
                    continue
                }
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
                guard file.lastPathComponent == "\(record.operationID).json" else {
                    corruptCount += 1
                    continue
                }
                try validate(record)
                records.append(record)
            } catch {
                corruptCount += 1
                let redacted = LogRedaction.redact(error.localizedDescription)
                Logger.signing.warning(
                    "Unreadable signing recovery record \(file.lastPathComponent, privacy: .public): \(redacted, privacy: .public)"
                )
            }
        }
        return (records.sorted { $0.updatedAt > $1.updatedAt }, corruptCount)
    }

    func unresolvedRecords() -> [Record] {
        do {
            return try loadAll().records.filter { $0.state == .cleanupPending || $0.lastError != nil }
        } catch {
            return []
        }
    }

    @discardableResult
    func reconcile(
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        signedRoot: URL = FileManager.default.signed,
        rowExists: (String) throws -> Bool,
        isOperationActive: (String) -> Bool = { AppOperationRegistry.shared.knowsProduction(of: $0) },
        removeDirectory: (URL, URL) throws -> Bool = { target, allowedRoot in
            try CleanupRemovalPolicy.remove(target, beneath: allowedRoot) != nil
        },
        now: Date = Date()
    ) -> RecoveryReport {
        let loaded: (records: [Record], corruptCount: Int)
        do {
            loaded = try loadAll()
        } catch {
            let redacted = LogRedaction.redact(error.localizedDescription)
            Logger.signing.error("Could not load signing recovery journal: \(redacted, privacy: .public)")
            return .empty
        }

        var report = RecoveryReport.empty
        report.corruptJournalCount = loaded.corruptCount

        for var record in loaded.records {
            if isOperationActive(record.operationID) {
                report.deferredCount += 1
                continue
            }

            let committedInStore: Bool
            do {
                committedInStore = try rowExists(record.operationID)
            } catch {
                let redacted = LogRedaction.redact(error.localizedDescription)
                Logger.signing.warning(
                    "Deferring signing recovery for \(record.operationID, privacy: .public); store unavailable: \(redacted, privacy: .public)"
                )
                report.deferredCount += 1
                report.unresolved.append(record)
                continue
            }

            var errors: [String] = []

            let workDir = temporaryRoot.appendingPathComponent(record.workDirectoryName, isDirectory: true)
            do {
                if try removeDirectory(workDir, temporaryRoot) {
                    report.cleanedWorkDirectories += 1
                }
            } catch {
                let redacted = LogRedaction.redact(error.localizedDescription)
                errors.append("temp: \(redacted)")
            }

            let signedDir = signedRoot.appendingPathComponent(record.operationID, isDirectory: true)
            if committedInStore || record.committedToDatabase || record.state == .committed {
                report.preservedCommittedSignedDirectories += 1
            } else {
                do {
                    if try removeDirectory(signedDir, signedRoot) {
                        report.cleanedUncommittedSignedDirectories += 1
                    }
                } catch {
                    let redacted = LogRedaction.redact(error.localizedDescription)
                    errors.append("signed: \(redacted)")
                }
            }

            if errors.isEmpty {
                do {
                    try remove(operationID: record.operationID)
                } catch {
                    let redacted = LogRedaction.redact(error.localizedDescription)
                    Logger.signing.warning(
                        "Failed removing resolved signing recovery journal \(record.operationID, privacy: .public): \(redacted, privacy: .public)"
                    )
                }
            } else {
                record.state = .cleanupPending
                record.cleanupAttempts += 1
                record.lastError = errors.joined(separator: "; ")
                record.updatedAt = now
                do {
                    try save(record)
                } catch {
                    let redacted = LogRedaction.redact(error.localizedDescription)
                    Logger.signing.error(
                        "Failed saving retry state for signing recovery \(record.operationID, privacy: .public): \(redacted, privacy: .public)"
                    )
                }
                report.unresolved.append(record)
            }
        }

        return report
    }

    @discardableResult
    static func recoverOnLaunch() -> RecoveryReport {
        guard let lease = AppOperationRegistry.shared.acquireCleanup() else { return .empty }
        defer { withExtendedLifetime(lease) {} }
        return defaultJournal.reconcile { uuid in
            try Storage.shared.containsCommittedSigned(uuid: uuid)
        }
    }

    private func loadRecord(operationID: String) throws -> Record? {
        let url = recordURL(for: operationID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        try validate(record)
        return record
    }

    private func recordURL(for operationID: String) -> URL {
        root.appendingPathComponent("\(operationID).json")
    }

    private func validate(_ record: Record) throws {
        guard UUID(uuidString: record.operationID) != nil,
              record.appName.utf8.count <= 1024,
              isSafeComponent(record.workDirectoryName) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let source = record.sourceAppUUID, UUID(uuidString: source) == nil {
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
