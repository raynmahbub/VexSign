// MARK: - VexSign-owned container storage
//
// All containers live under one Application Support directory. Every operation
// is serialized by this actor and every path is derived from a generated id and
// validated components. Nothing in this file creates an iOS app sandbox.

import Foundation
import UniformTypeIdentifiers
import NimbleExtensions

struct ContainerRecoveryReport: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case recovered
            case unresolved
            case invalid
            case orphaned
        }

        let item: String
        let containerID: String?
        let status: Status
        let detail: String
    }

    let entries: [Entry]

    static let empty = ContainerRecoveryReport(entries: [])

    var needsAttention: Bool {
        entries.contains { $0.status == .unresolved || $0.status == .invalid }
    }

    var actionableDescription: String? {
        let retained = entries.filter { $0.status == .unresolved || $0.status == .invalid }
        guard !retained.isEmpty else { return nil }
        let details = retained.map { "\($0.item): \($0.detail)" }.joined(separator: "; ")
        return ContainerError.persistenceFailed(
            "Recovery could not finish for \(retained.count) staged item(s). "
                + "The retained copies were not deleted. \(details)"
        ).localizedDescription
    }
}

actor ContainerStore {
    private let root: URL
    private let manager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) {
        manager = fileManager
        if let root {
            self.root = root
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.root = support.appendingPathComponent("VexSignContainers", isDirectory: true)
        }
    }

    var rootURL: URL { root }

    // MARK: - Setup and recovery

    @discardableResult
    func prepare() throws -> ContainerRecoveryReport {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        var diagnostics: [ContainerRecoveryReport.Entry] = []
        let stagedItems = try manager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        // A `.replaced` directory is the pre-transaction container. It is never
        // discarded merely because another destination exists: without a durable
        // commit marker, that destination may be a collision or a completed but
        // uncommitted installation.
        for item in stagedItems where item.lastPathComponent.hasSuffix(".replaced") {
            diagnostics.append(contentsOf: try _recoverReplacement(item, collisionPolicy: .retainBoth))
        }

        // Incomplete entries were never committed. They are safe to clean, but a
        // cleanup failure is a recovery result, not permission to remove staging.
        for item in stagedItems where !item.lastPathComponent.hasSuffix(".replaced") {
            if item.lastPathComponent.hasSuffix(".incomplete") {
                diagnostics.append(_removeOrphan(item))
            } else {
                diagnostics.append(ContainerRecoveryReport.Entry(
                    item: item.lastPathComponent,
                    containerID: nil,
                    status: .invalid,
                    detail: "The staging entry is not a recognized transaction and was retained."
                ))
            }
        }

        // Older versions could leave an incomplete entry directly under the
        // store root. Its suffix proves it was never a published container.
        let rootItems = try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for item in rootItems where item.lastPathComponent.hasSuffix(".incomplete") {
            diagnostics.append(_removeOrphan(item))
        }
        return ContainerRecoveryReport(entries: diagnostics)
    }

    // MARK: - Reading

    func list() throws -> [AppContainerRecord] {
        guard manager.fileExists(atPath: root.path) else { return [] }
        let directories = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var records: [AppContainerRecord] = []
        for directory in directories where ContainerPathPolicy.isValidIdentifier(directory.lastPathComponent) {
            guard let record = try? loadRecord(id: directory.lastPathComponent) else { // try? ok: damaged metadata is surfaced as a container state
                records.append(_placeholder(id: directory.lastPathComponent, state: .corrupted))
                continue
            }
            records.append(record)
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    func record(id: String) throws -> AppContainerRecord {
        guard ContainerPathPolicy.isValidIdentifier(id) else { throw ContainerError.invalidIdentifier }
        do { return try loadRecord(id: id) }
        catch { throw ContainerError.corruptedContainer }
    }

    func containerURL(id: String) throws -> URL {
        try ContainerPathPolicy.containerRoot(in: root, id: id)
    }

    func resourceURL(id: String, relativePath: String) throws -> URL {
        try ContainerPathPolicy.resourceURL(in: containerURL(id: id), relativePath: relativePath)
    }

    func usage(id: String) throws -> ContainerUsage {
        let url = try containerURL(id: id)
        let bytes = CleanupRemovalPolicy.allocatedSizeWithoutFollowingSymlinks(at: url)
        let count = try _resourceFiles(in: url).count
        return ContainerUsage(allocatedBytes: bytes, fileCount: count)
    }

    // MARK: - Lifecycle

    func create(
        displayName: String,
        detail: String = "",
        application: ContainerAppReference? = nil,
        checkpoint: (@Sendable () throws -> Void)? = nil
    ) throws -> AppContainerRecord {
        try check(checkpoint)
        let name = try ContainerPathPolicy.displayName(displayName)
        if try list().contains(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ContainerError.duplicateName
        }
        let id = ContainerPathPolicy.makeIdentifier()
        let now = Date()
        let record = AppContainerRecord(
            id: id, schemaVersion: AppContainerRecord.currentSchemaVersion,
            kind: .managedStorage, state: .active, displayName: name, detail: detail,
            createdAt: now, updatedAt: now, application: application,
            compatibility: .empty, preferences: [:], resources: [], runtimeHint: .none
        )
        try _publishNew(record, checkpoint: checkpoint)
        return record
    }

    func rename(id: String, to name: String) throws -> AppContainerRecord {
        var record = try record(id: id)
        let safe = try ContainerPathPolicy.displayName(name)
        if try list().contains(where: {
            $0.id != id && $0.displayName.caseInsensitiveCompare(safe) == .orderedSame
        }) { throw ContainerError.duplicateName }
        record.displayName = safe
        record.updatedAt = Date()
        try save(record)
        return record
    }

    func update(
        id: String,
        detail: String? = nil,
        compatibility: ContainerCompatibility? = nil,
        runtimeHint: ContainerRuntimeHint? = nil
    ) throws -> AppContainerRecord {
        var record = try record(id: id)
        if let detail { record.detail = detail }
        if let compatibility { record.compatibility = compatibility }
        if let runtimeHint { record.runtimeHint = runtimeHint }
        record.updatedAt = Date()
        try save(record)
        return record
    }

    func associate(id: String, application: ContainerAppReference?) throws -> AppContainerRecord {
        var record = try record(id: id)
        record.application = application
        record.updatedAt = Date()
        try save(record)
        return record
    }

    func setPreference(id: String, key: String, value: ContainerPreferenceValue?) throws -> AppContainerRecord {
        var record = try record(id: id)
        let safeKey = try ContainerPathPolicy.safeComponent(key)
        if let value { record.preferences[safeKey] = value }
        else { record.preferences.removeValue(forKey: safeKey) }
        record.updatedAt = Date()
        try save(record)
        return record
    }

    func delete(id: String) throws {
        let url = try containerURL(id: id)
        guard ContainerPathPolicy.isContained(url, in: root) else { throw ContainerError.inaccessibleContainer }
        guard manager.fileExists(atPath: url.path) else { throw ContainerError.missingContainer }
        try manager.removeItem(at: url)
    }

    // MARK: - Resources

    func addResource(
        id: String,
        from source: URL,
        relativePath: String,
        checkpoint: (@Sendable () throws -> Void)? = nil
    ) throws -> AppContainerRecord {
        try check(checkpoint)
        var record = try record(id: id)
        let safe = try ContainerPathPolicy.safeRelativePath(relativePath)
        let destination = try ContainerPathPolicy.resourceURL(in: containerURL(id: id), relativePath: safe)
        guard !manager.fileExists(atPath: destination.path) else {
            throw ContainerError.resourceExists(safe)
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ContainerError.unsafeResourcePath(source.lastPathComponent)
        }
        let size = Int64(values.fileSize ?? 0)
        guard size >= 0, size <= ContainerPathPolicy.maximumResourceBytes else { throw ContainerError.resourceTooLarge }

        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let staged = try _stagingFile(prefix: "resource")
        try manager.copyItem(at: source, to: staged)
        try check(checkpoint)
        guard let hash = try FileIntegrity.sha256(of: staged, cancellationCheck: { try check(checkpoint) }) else {
            try? manager.removeItem(at: staged) // try? ok: failed staging cleanup
            throw ContainerError.corruptedContainer
        }
        try check(checkpoint)
        do {
            try manager.moveItem(at: staged, to: destination)
        } catch {
            try? manager.removeItem(at: staged) // try? ok: failed staging cleanup
            throw ContainerError.persistenceFailed(error.localizedDescription)
        }
        let resource = ContainerResource(
            relativePath: safe, byteCount: size, sha256: hash, addedAt: Date(),
            typeIdentifier: UTType(filenameExtension: destination.pathExtension)?.identifier
        )
        record.resources.append(resource)
        record.resources.sort { $0.relativePath < $1.relativePath }
        record.updatedAt = Date()
        do { try save(record) }
        catch {
            try? manager.removeItem(at: destination) // try? ok: roll back an uncommitted resource
            throw error
        }
        return record
    }

    func removeResource(id: String, relativePath: String) throws -> AppContainerRecord {
        var record = try record(id: id)
        let safe = try ContainerPathPolicy.safeRelativePath(relativePath)
        guard let index = record.resources.firstIndex(where: { $0.relativePath == safe }) else {
            throw ContainerError.resourceMissing(safe)
        }
        let url = try ContainerPathPolicy.resourceURL(in: containerURL(id: id), relativePath: safe)
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        record.resources.remove(at: index)
        record.updatedAt = Date()
        try save(record)
        return record
    }

    func verifyResources(id: String) throws -> Bool {
        let record = try record(id: id)
        let container = try containerURL(id: id)
        for resource in record.resources {
            let url = try ContainerPathPolicy.resourceURL(in: container, relativePath: resource.relativePath)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), // try? ok: unreadable metadata rejects the resource
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? 0) == resource.byteCount,
                  try FileIntegrity.sha256(of: url) == resource.sha256 else { return false }
        }
        return true
    }

    // MARK: - Duplicate and restore

    func duplicate(id: String, displayName: String, checkpoint: (@Sendable () throws -> Void)? = nil) throws -> AppContainerRecord {
        try check(checkpoint)
        let source = try record(id: id)
        let name = try ContainerPathPolicy.displayName(displayName)
        let existing = try list()
        guard !existing.contains(where: {
            $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw ContainerError.duplicateName }
        var copy = _record(source, replacingID: ContainerPathPolicy.makeIdentifier())
        copy.displayName = name
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.runtimeHint = .none
        var resources: [(relativePath: String, url: URL)] = []
        for resource in source.resources {
            try check(checkpoint)
            let url = try ContainerPathPolicy.resourceURL(
                in: containerURL(id: id),
                relativePath: resource.relativePath
            )
            resources.append((resource.relativePath, url))
        }
        return try installValidated(copy, stagedResources: resources, forceID: copy.id, checkpoint: checkpoint)
    }

    /// Creates a container from already validated staged files. Used only by
    /// restore, after every checksum has been verified in a temporary directory.
    func installValidated(
        _ record: AppContainerRecord,
        stagedResources: [(relativePath: String, url: URL)],
        forceID: String? = nil,
        checkpoint: (@Sendable () throws -> Void)? = nil
    ) throws -> AppContainerRecord {
        try check(checkpoint)
        let existing = try list()
        var installed = record
        if let forceID {
            guard ContainerPathPolicy.isValidIdentifier(forceID) else { throw ContainerError.invalidIdentifier }
            installed = _record(installed, replacingID: forceID)
        } else if existing.contains(where: { $0.id == record.id }) {
            installed = _record(installed, replacingID: ContainerPathPolicy.makeIdentifier())
        }
        guard !existing.contains(where: { $0.id == installed.id }) else {
            throw ContainerArchiveError.destinationExists
        }
        installed.schemaVersion = min(record.schemaVersion, AppContainerRecord.currentSchemaVersion)
        installed.state = .active

        let final = try containerURL(id: installed.id)
        let interim = _stagingURL.appendingPathComponent(installed.id + ".incomplete", isDirectory: true)
        guard !manager.fileExists(atPath: final.path), !manager.fileExists(atPath: interim.path) else {
            throw ContainerArchiveError.destinationExists
        }
        try manager.createDirectory(
            at: interim.appendingPathComponent("Resources", isDirectory: true),
            withIntermediateDirectories: true
        )

        do {
            try _writeMetadata(installed, in: interim)
            var copied = Set<String>()
            for item in stagedResources {
                try check(checkpoint)
                let safe = try ContainerPathPolicy.safeRelativePath(item.relativePath)
                guard safe == item.relativePath,
                      installed.resources.contains(where: { $0.relativePath == safe }),
                      copied.insert(safe).inserted else {
                    throw ContainerArchiveError.archiveInvalid
                }
                let to = try ContainerPathPolicy.resourceURL(in: interim, relativePath: safe)
                try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: item.url, to: to)
            }
            guard copied.count == installed.resources.count else {
                throw ContainerArchiveError.archiveInvalid
            }
            switch _validateContainer(at: interim, id: installed.id) {
            case .valid:
                break
            case .invalid, .inaccessible:
                throw ContainerError.corruptedContainer
            }
            try check(checkpoint)
            if let failure = _movePreservingFailure(from: interim, to: final) {
                throw ContainerError.persistenceFailed(failure)
            }
            return installed
        } catch {
            let installationError = error
            if manager.fileExists(atPath: interim.path) {
                do { try manager.removeItem(at: interim) }
                catch {
                    throw ContainerError.persistenceFailed(
                        "Installation failed (\(installationError.localizedDescription)); "
                            + "the incomplete staging directory was retained because cleanup failed "
                            + "(\(error.localizedDescription))."
                    )
                }
            }
            throw installationError
        }
    }

    /// Moves an explicitly authorized replacement target aside so a failed
    /// restore can put the original back instead of losing user data.
    func detachForReplacement(id: String) throws -> URL? {
        let url = try containerURL(id: id)
        guard manager.fileExists(atPath: url.path) else { return nil }
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let held = staging.appendingPathComponent(id + ".replaced", isDirectory: true)
        guard !manager.fileExists(atPath: held.path) else {
            throw ContainerError.persistenceFailed(
                "An earlier replacement for \(id) still has recovery data in staging."
            )
        }
        try manager.moveItem(at: url, to: held)
        return held
    }

    func commitReplacement(_ held: URL?) throws {
        guard let held else { return }
        guard manager.fileExists(atPath: held.path) else {
            throw ContainerError.persistenceFailed(
                "The staged original disappeared before replacement could commit."
            )
        }
        let suffix = ".replaced"
        guard held.lastPathComponent.hasSuffix(suffix) else {
            throw ContainerError.persistenceFailed("The replacement recovery path is invalid and was retained.")
        }
        let id = String(held.lastPathComponent.dropLast(suffix.count))
        guard ContainerPathPolicy.isValidIdentifier(id),
              held.deletingLastPathComponent().standardizedFileURL == _stagingURL.standardizedFileURL else {
            throw ContainerError.persistenceFailed("The replacement recovery path is invalid and was retained.")
        }
        let target = try containerURL(id: id)
        guard manager.fileExists(atPath: target.path) else {
            throw ContainerError.persistenceFailed("The replacement destination is missing; the original was retained.")
        }
        switch _validateContainer(at: target, id: id) {
        case .valid:
            do { try manager.removeItem(at: held) }
            catch {
                if manager.fileExists(atPath: held.path) { throw error }
            }
        case .invalid(let detail), .inaccessible(let detail):
            throw ContainerError.persistenceFailed(
                "The replacement destination could not be proven complete. The original was retained. \(detail)"
            )
        }
    }

    func rollbackReplacement(_ held: URL?, id: String) throws {
        guard let held else { return }
        guard manager.fileExists(atPath: held.path) else {
            throw ContainerError.persistenceFailed(
                "The original container for \(id) is no longer present in replacement staging."
            )
        }
        let diagnostics = try _recoverReplacement(held, collisionPolicy: .restoreOriginal)
        let unresolved = diagnostics.filter { $0.status == .unresolved || $0.status == .invalid }
        if !unresolved.isEmpty {
            let detail = unresolved.map { "\($0.item): \($0.detail)" }.joined(separator: "; ")
            throw ContainerError.persistenceFailed("Automatic rollback did not finish. \(detail)")
        }
        guard diagnostics.contains(where: { $0.status == .recovered }) else {
            throw ContainerError.persistenceFailed(
                "The original container for \(id) could not be confirmed after rollback."
            )
        }
    }

    func saveRecordForExport(_ record: AppContainerRecord) throws {
        try save(record)
    }

    // MARK: - Internals

    private enum RecoveryCollisionPolicy: Equatable {
        case retainBoth
        case restoreOriginal
    }

    private enum ContainerValidation {
        case valid
        case invalid(String)
        case inaccessible(String)
    }

    private var _stagingURL: URL {
        root.appendingPathComponent(".staging", isDirectory: true)
    }

    private func _recoverReplacement(
        _ held: URL,
        collisionPolicy: RecoveryCollisionPolicy
    ) throws -> [ContainerRecoveryReport.Entry] {
        let suffix = ".replaced"
        let name = held.lastPathComponent
        guard name.hasSuffix(suffix) else {
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: nil,
                status: .invalid,
                detail: "The replacement transaction name is malformed and was retained."
            )]
        }

        let id = String(name.dropLast(suffix.count))
        guard held.deletingLastPathComponent().standardizedFileURL == _stagingURL.standardizedFileURL else {
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: nil,
                status: .invalid,
                detail: "The replacement transaction is outside staging and was retained."
            )]
        }
        guard ContainerPathPolicy.isValidIdentifier(id) else {
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: nil,
                status: .invalid,
                detail: "The replacement transaction has an invalid container identifier and was retained."
            )]
        }

        do {
            let values = try held.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                return [ContainerRecoveryReport.Entry(
                    item: name,
                    containerID: id,
                    status: .invalid,
                    detail: "The recoverable item is not a safe directory and was retained."
                )]
            }
        } catch {
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: id,
                status: .unresolved,
                detail: "The recoverable directory could not be inspected and was retained: "
                    + error.localizedDescription
            )]
        }

        switch _validateContainer(at: held, id: id) {
        case .valid:
            break
        case .invalid(let detail):
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: id,
                status: .invalid,
                detail: "The staged original is not a complete valid container and was retained. \(detail)"
            )]
        case .inaccessible(let detail):
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: id,
                status: .unresolved,
                detail: "The staged original could not be inspected and was retained. \(detail)"
            )]
        }

        let target = try containerURL(id: id)
        guard manager.fileExists(atPath: target.path) else {
            if let failure = _movePreservingFailure(from: held, to: target) {
                return [ContainerRecoveryReport.Entry(
                    item: name,
                    containerID: id,
                    status: .unresolved,
                    detail: "The original could not be restored and remains recoverable: \(failure)"
                )]
            }
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: id,
                status: .recovered,
                detail: "The original container was restored to its missing destination."
            )]
        }

        let validation = _validateContainer(at: target, id: id)
        switch validation {
        case .valid:
            if collisionPolicy == .retainBoth {
                return [ContainerRecoveryReport.Entry(
                    item: name,
                    containerID: id,
                    status: .unresolved,
                    detail: "A valid destination also exists. Both copies were retained for explicit resolution."
                )]
            }
        case .inaccessible(let detail):
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: id,
                status: .unresolved,
                detail: "The destination could not be inspected. Both copies were retained. \(detail)"
            )]
        case .invalid:
            break
        }

        let quarantine = _stagingURL.appendingPathComponent(id + ".recovery.incomplete", isDirectory: true)
        guard !manager.fileExists(atPath: quarantine.path) else {
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: id,
                status: .unresolved,
                detail: "A partial-install quarantine already exists. No copy was overwritten or deleted."
            )]
        }
        if let failure = _movePreservingFailure(from: target, to: quarantine) {
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: id,
                status: .unresolved,
                detail: "The conflicting destination could not be moved aside. Both copies were retained: \(failure)"
            )]
        }
        if let failure = _movePreservingFailure(from: held, to: target) {
            return [ContainerRecoveryReport.Entry(
                item: name,
                containerID: id,
                status: .unresolved,
                detail: "The destination was quarantined, but the original could not be restored. "
                    + "The original remains in staging: \(failure)"
            )]
        }

        var result = [ContainerRecoveryReport.Entry(
            item: name,
            containerID: id,
            status: .recovered,
            detail: "The original container was restored after an interrupted replacement."
        )]
        result.append(_removeOrphan(quarantine, containerID: id))
        return result
    }

    private func _movePreservingFailure(from source: URL, to destination: URL) -> String? {
        do {
            try manager.moveItem(at: source, to: destination)
            return nil
        } catch {
            // A filesystem implementation can report an error after completing
            // the rename. Only accept that state when the destination is the
            // complete container the source was supposed to become.
            if !manager.fileExists(atPath: source.path), manager.fileExists(atPath: destination.path),
               let expectedID = _expectedContainerID(forMoveFrom: source, to: destination) {
                if case .valid = _validateContainer(at: destination, id: expectedID) { return nil }
            }
            return error.localizedDescription
        }
    }

    private func _expectedContainerID(forMoveFrom source: URL, to destination: URL) -> String? {
        if destination.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
           ContainerPathPolicy.isValidIdentifier(destination.lastPathComponent) {
            return destination.lastPathComponent
        }
        let replacementSuffix = ".replaced"
        if source.lastPathComponent.hasSuffix(replacementSuffix) {
            let id = String(source.lastPathComponent.dropLast(replacementSuffix.count))
            return ContainerPathPolicy.isValidIdentifier(id) ? id : nil
        }
        let incompleteSuffix = ".incomplete"
        if source.lastPathComponent.hasSuffix(incompleteSuffix) {
            let id = String(source.lastPathComponent.dropLast(incompleteSuffix.count))
            return ContainerPathPolicy.isValidIdentifier(id) ? id : nil
        }
        return nil
    }

    private func _removeOrphan(
        _ item: URL,
        containerID: String? = nil
    ) -> ContainerRecoveryReport.Entry {
        do {
            try manager.removeItem(at: item)
            return ContainerRecoveryReport.Entry(
                item: item.lastPathComponent,
                containerID: containerID,
                status: .orphaned,
                detail: "An uncommitted staging item was safely removed."
            )
        } catch {
            if !manager.fileExists(atPath: item.path) {
                return ContainerRecoveryReport.Entry(
                    item: item.lastPathComponent,
                    containerID: containerID,
                    status: .orphaned,
                    detail: "The uncommitted staging item was already absent."
                )
            }
            return ContainerRecoveryReport.Entry(
                item: item.lastPathComponent,
                containerID: containerID,
                status: .unresolved,
                detail: "The staging item could not be removed and was retained: \(error.localizedDescription)"
            )
        }
    }

    private func _record(_ record: AppContainerRecord, replacingID id: String) -> AppContainerRecord {
        AppContainerRecord(
            id: id,
            schemaVersion: record.schemaVersion,
            kind: record.kind,
            state: record.state,
            displayName: record.displayName,
            detail: record.detail,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            application: record.application,
            compatibility: record.compatibility,
            preferences: record.preferences,
            resources: record.resources,
            runtimeHint: record.runtimeHint
        )
    }

    private func _writeMetadata(_ record: AppContainerRecord, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let metadata = directory.appendingPathComponent("metadata.json", isDirectory: false)
        try encoder.encode(record).write(to: metadata, options: .atomic)
    }

    private func _validateContainer(at directory: URL, id: String) -> ContainerValidation {
        do {
            _ = try manager.attributesOfItem(atPath: directory.path)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                return .invalid("The destination is not a safe container directory.")
            }
        } catch {
            return .inaccessible(error.localizedDescription)
        }

        let metadata = directory.appendingPathComponent("metadata.json", isDirectory: false)
        let legacy = directory.appendingPathComponent("info.json", isDirectory: false)
        let metadataURL: URL
        if manager.fileExists(atPath: metadata.path) {
            metadataURL = metadata
        } else if manager.fileExists(atPath: legacy.path) {
            metadataURL = legacy
        } else {
            return .invalid("The destination has no container metadata.")
        }

        let data: Data
        do {
            let values = try metadataURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return .invalid("The destination metadata is not a safe regular file.")
            }
            data = try Data(contentsOf: metadataURL)
        } catch {
            return .inaccessible(error.localizedDescription)
        }

        let record: AppContainerRecord
        do {
            record = try ContainerMigration.normalize(data, fallbackID: id)
        } catch {
            return .invalid(error.localizedDescription)
        }
        guard record.id == id else {
            return .invalid("The destination metadata identifies a different container.")
        }

        var seen = Set<String>()
        for resource in record.resources {
            let safe: String
            do { safe = try ContainerPathPolicy.safeRelativePath(resource.relativePath) }
            catch { return .invalid(error.localizedDescription) }
            guard safe == resource.relativePath, seen.insert(safe).inserted else {
                return .invalid("The destination metadata contains an unsafe or duplicate resource path.")
            }
            let url: URL
            do { url = try ContainerPathPolicy.resourceURL(in: directory, relativePath: safe) }
            catch { return .invalid(error.localizedDescription) }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      Int64(values.fileSize ?? -1) == resource.byteCount else {
                    return .invalid("A destination resource is missing or incomplete: \(safe)")
                }
            } catch {
                if manager.fileExists(atPath: url.path) { return .inaccessible(error.localizedDescription) }
                return .invalid("A destination resource is missing: \(safe)")
            }
            guard let digest = FileIntegrity.sha256(of: url) else {
                return .inaccessible("A destination resource could not be read: \(safe)")
            }
            guard digest == resource.sha256 else {
                return .invalid("A destination resource failed integrity validation: \(safe)")
            }
        }
        return .valid
    }

    private func check(_ checkpoint: (@Sendable () throws -> Void)?) throws {
        if let checkpoint { try checkpoint() } else { try Task.checkCancellation() }
    }

    private func loadRecord(id: String) throws -> AppContainerRecord {
        let container = try containerURL(id: id)
        let url = container.appendingPathComponent("metadata.json", isDirectory: false)
        let data: Data
        var migratedFromLegacy = false
        do { data = try Data(contentsOf: url) }
        catch {
            let legacy = container.appendingPathComponent("info.json", isDirectory: false)
            data = try Data(contentsOf: legacy)
            migratedFromLegacy = true
        }
        var record = try ContainerMigration.normalize(data, fallbackID: id)
        guard record.id == id else { throw ContainerError.corruptedContainer }
        let decodedResources = record.resources
        var verified: [ContainerResource] = []
        for resource in decodedResources {
            guard let path = try? ContainerPathPolicy.safeRelativePath(resource.relativePath) else { continue } // try? ok: drop an unsafe recorded path
            verified.append(ContainerResource(
                relativePath: path, byteCount: resource.byteCount, sha256: resource.sha256,
                addedAt: resource.addedAt, typeIdentifier: resource.typeIdentifier
            ))
        }
        record.resources = verified
        if record.schemaVersion < AppContainerRecord.currentSchemaVersion {
            record.schemaVersion = AppContainerRecord.currentSchemaVersion
            try save(record)
        } else if migratedFromLegacy {
            try save(record)
        }
        return record
    }

    private func save(_ record: AppContainerRecord) throws {
        guard ContainerPathPolicy.isValidIdentifier(record.id) else { throw ContainerError.invalidIdentifier }
        let container = try containerURL(id: record.id)
        try manager.createDirectory(at: container, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        let metadata = container.appendingPathComponent("metadata.json", isDirectory: false)
        let temporary = try _stagingFile(prefix: "metadata")
        do {
            try data.write(to: temporary, options: .atomic)
            if manager.fileExists(atPath: metadata.path) {
                try manager.replaceItemAt(metadata, withItemAt: temporary,
                                                      backupItemName: nil, options: [.usingNewMetadataOnly])
            } else {
                try manager.moveItem(at: temporary, to: metadata)
            }
        } catch {
            try? manager.removeItem(at: temporary) // try? ok: failed metadata staging cleanup
            throw ContainerError.persistenceFailed(error.localizedDescription)
        }
    }

    private func _publishNew(_ record: AppContainerRecord, checkpoint: (@Sendable () throws -> Void)?) throws {
        try check(checkpoint)
        let final = try containerURL(id: record.id)
        guard !manager.fileExists(atPath: final.path) else { throw ContainerArchiveError.destinationExists }
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let interim = staging.appendingPathComponent(record.id + ".incomplete", isDirectory: true)
        try manager.createDirectory(at: interim, withIntermediateDirectories: true)
        try manager.createDirectory(at: interim.appendingPathComponent("Resources", isDirectory: true),
                                                withIntermediateDirectories: true)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(record).write(to: interim.appendingPathComponent("metadata.json"),
                                             options: .atomic)
            try check(checkpoint)
            try manager.moveItem(at: interim, to: final)
        } catch {
            try? manager.removeItem(at: interim) // try? ok: incomplete container never published
            if error is CancellationError { throw ContainerError.operationInterrupted }
            throw error
        }
    }

    private func _stagingFile(prefix: String) throws -> URL {
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging.appendingPathComponent("\(prefix)-\(UUID().uuidString).incomplete", isDirectory: false)
    }

    private func _resourceFiles(in container: URL) throws -> [URL] {
        let resources = container.appendingPathComponent("Resources", isDirectory: true)
        guard manager.fileExists(atPath: resources.path) else { return [] }
        return try manager.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
    }

    private func _placeholder(id: String, state: AppContainerState) -> AppContainerRecord {
        let now = Date()
        return AppContainerRecord(
            id: id, schemaVersion: AppContainerRecord.currentSchemaVersion, kind: .managedStorage,
            state: state, displayName: .localized("Damaged container"), detail: "",
            createdAt: now, updatedAt: now, application: nil, compatibility: .empty,
            preferences: [:], resources: [], runtimeHint: .none
        )
    }
}
