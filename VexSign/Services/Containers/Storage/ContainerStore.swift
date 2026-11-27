// MARK: - VexSign-owned container storage
//
// All containers live under one Application Support directory. Every operation
// is serialized by this actor and every path is derived from a generated id and
// validated components. Nothing in this file creates an iOS app sandbox.

import Foundation
import UniformTypeIdentifiers
import NimbleExtensions

actor ContainerStore {
    private let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.root = support.appendingPathComponent("VexSignContainers", isDirectory: true)
        }
    }

    var rootURL: URL { root }

    // MARK: - Setup and recovery

    func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        if manager.fileExists(atPath: staging.path) {
            // A replacement interrupted between detach and commit must recover
            // in favour of the original when no new container took its place.
            let held = try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            for item in held where item.lastPathComponent.hasSuffix(".replaced") {
                let id = String(item.lastPathComponent.dropLast(".replaced".count))
                guard ContainerPathPolicy.isValidIdentifier(id) else { continue }
                let target = try ContainerPathPolicy.containerRoot(in: root, id: id)
                if manager.fileExists(atPath: target.path) {
                    try? manager.removeItem(at: item) // try? ok: the replacement already committed
                } else {
                    try? manager.moveItem(at: item, to: target) // try? ok: unrecoverable items stay in staging
                }
            }
            try manager.removeItem(at: staging)
        }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        for item in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard item.lastPathComponent.hasSuffix(".incomplete") else { continue }
            try? manager.removeItem(at: item) // try? ok: abandoned staging cleanup is best-effort
        }
    }

    // MARK: - Reading

    func list() throws -> [AppContainerRecord] {
        let manager = FileManager.default
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
        guard FileManager.default.fileExists(atPath: url.path) else { throw ContainerError.missingContainer }
        try FileManager.default.removeItem(at: url)
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
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ContainerError.resourceExists(safe)
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ContainerError.unsafeResourcePath(source.lastPathComponent)
        }
        let size = Int64(values.fileSize ?? 0)
        guard size >= 0, size <= ContainerPathPolicy.maximumResourceBytes else { throw ContainerError.resourceTooLarge }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let staged = try _stagingFile(prefix: "resource")
        try FileManager.default.copyItem(at: source, to: staged)
        try check(checkpoint)
        guard let hash = try FileIntegrity.sha256(of: staged, cancellationCheck: { try check(checkpoint) }) else {
            try? FileManager.default.removeItem(at: staged) // try? ok: failed staging cleanup
            throw ContainerError.corruptedContainer
        }
        try check(checkpoint)
        do {
            try FileManager.default.moveItem(at: staged, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staged) // try? ok: failed staging cleanup
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
            try? FileManager.default.removeItem(at: destination) // try? ok: roll back an uncommitted resource
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
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
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
        var copy = source
        copy.id = ContainerPathPolicy.makeIdentifier()
        copy.displayName = name
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.runtimeHint = .none
        try _publishNew(copy, checkpoint: checkpoint)
        do {
            for resource in source.resources {
                try check(checkpoint)
                let from = try ContainerPathPolicy.resourceURL(in: containerURL(id: id), relativePath: resource.relativePath)
                let to = try ContainerPathPolicy.resourceURL(in: containerURL(id: copy.id), relativePath: resource.relativePath)
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: from, to: to)
            }
            guard try verifyResources(id: copy.id) else {
                throw ContainerError.corruptedContainer
            }
            return try record(id: copy.id)
        } catch {
            try? delete(id: copy.id) // try? ok: the duplicate was never published to the UI
            throw error
        }
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
        var installed = record
        if let forceID {
            guard ContainerPathPolicy.isValidIdentifier(forceID) else { throw ContainerError.invalidIdentifier }
            installed.id = forceID
        } else if try list().contains(where: { $0.id == record.id }) {
            installed.id = ContainerPathPolicy.makeIdentifier()
        }
        guard !try list().contains(where: { $0.id == installed.id }) else {
            throw ContainerArchiveError.destinationExists
        }
        installed.schemaVersion = min(record.schemaVersion, AppContainerRecord.currentSchemaVersion)
        installed.state = .active
        try _publishNew(installed, checkpoint: checkpoint)
        do {
            for item in stagedResources {
                try check(checkpoint)
                let to = try ContainerPathPolicy.resourceURL(in: containerURL(id: installed.id), relativePath: item.relativePath)
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: item.url, to: to)
            }
            guard try verifyResources(id: installed.id) else { throw ContainerError.corruptedContainer }
            return try record(id: installed.id)
        } catch {
            try? delete(id: installed.id) // try? ok: restore never publishes an unverified container
            throw error
        }
    }

    /// Moves an explicitly authorized replacement target aside so a failed
    /// restore can put the original back instead of losing user data.
    func detachForReplacement(id: String) throws -> URL? {
        let url = try containerURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let held = staging.appendingPathComponent(id + ".replaced", isDirectory: true)
        if FileManager.default.fileExists(atPath: held.path) {
            try FileManager.default.removeItem(at: held)
        }
        try FileManager.default.moveItem(at: url, to: held)
        return held
    }

    func commitReplacement(_ held: URL?) throws {
        guard let held else { return }
        if FileManager.default.fileExists(atPath: held.path) {
            try FileManager.default.removeItem(at: held)
        }
    }

    func rollbackReplacement(_ held: URL?, id: String) throws {
        guard let held, FileManager.default.fileExists(atPath: held.path) else { return }
        let url = try containerURL(id: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: held, to: url)
    }

    func saveRecordForExport(_ record: AppContainerRecord) throws {
        try save(record)
    }

    // MARK: - Internals

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
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        let metadata = container.appendingPathComponent("metadata.json", isDirectory: false)
        let temporary = try _stagingFile(prefix: "metadata")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: metadata.path) {
                try FileManager.default.replaceItemAt(metadata, withItemAt: temporary,
                                                      backupItemName: nil, options: [.usingNewMetadataOnly])
            } else {
                try FileManager.default.moveItem(at: temporary, to: metadata)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary) // try? ok: failed metadata staging cleanup
            throw ContainerError.persistenceFailed(error.localizedDescription)
        }
    }

    private func _publishNew(_ record: AppContainerRecord, checkpoint: (@Sendable () throws -> Void)?) throws {
        try check(checkpoint)
        let final = try containerURL(id: record.id)
        guard !FileManager.default.fileExists(atPath: final.path) else { throw ContainerArchiveError.destinationExists }
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let interim = staging.appendingPathComponent(record.id + ".incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: interim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: interim.appendingPathComponent("Resources", isDirectory: true),
                                                withIntermediateDirectories: true)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(record).write(to: interim.appendingPathComponent("metadata.json"),
                                             options: .atomic)
            try check(checkpoint)
            try FileManager.default.moveItem(at: interim, to: final)
        } catch {
            try? FileManager.default.removeItem(at: interim) // try? ok: incomplete container never published
            if error is CancellationError { throw ContainerError.operationInterrupted }
            throw error
        }
    }

    private func _stagingFile(prefix: String) throws -> URL {
        let staging = root.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging.appendingPathComponent("\(prefix)-\(UUID().uuidString).incomplete", isDirectory: false)
    }

    private func _resourceFiles(in container: URL) throws -> [URL] {
        let resources = container.appendingPathComponent("Resources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: resources.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
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
