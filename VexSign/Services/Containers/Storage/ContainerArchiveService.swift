// MARK: - Container export and restore
//
// Exports are ordinary ZIP archives holding a JSON manifest and container-owned
// resource files. Optional encryption reuses VexSign's authenticated BackupCrypto
// stream format; no new cryptographic format is invented here.

import Foundation
import ZIPFoundation
import NimbleExtensions

actor ContainerArchiveService {
    private let store: ContainerStore
    private let limits: ArchiveSafetyValidator.Limits
    private let appVersion: String

    init(
        store: ContainerStore,
        limits: ArchiveSafetyValidator.Limits = .default,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    ) {
        self.store = store
        self.limits = limits
        self.appVersion = appVersion
    }

    // MARK: - Export

    func export(
        id: String,
        password: String? = nil,
        checkpoint: (@Sendable () throws -> Void)? = nil
    ) async throws -> ContainerExport {
        try Self.check(checkpoint)
        var record = try await store.record(id: id)
        guard try await store.verifyResources(id: id) else { throw ContainerError.corruptedContainer }
        record.state = .active
        record.updatedAt = Date()
        try await store.saveRecordForExport(record)

        let manager = FileManager.default
        let work = manager.uniqueTemporaryDirectory("VexContainerWork")
        let pack = work.appendingPathComponent("pack", isDirectory: true)
        try manager.createDirectory(at: pack, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) } // try? ok: staging is private and no longer needed
        try Self.check(checkpoint)

        let manifest = ContainerExportManifest(
            format: ContainerExportManifest.format,
            formatVersion: ContainerExportManifest.currentFormatVersion,
            schemaVersion: record.schemaVersion,
            exportedAt: Date(), appVersion: appVersion, container: record
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: pack.appendingPathComponent("manifest.json", isDirectory: false), options: .atomic)
        try Self.check(checkpoint)

        for resource in record.resources {
            let from = try await store.resourceURL(id: id, relativePath: resource.relativePath)
            let to = pack.appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(resource.relativePath, isDirectory: false)
            try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: from, to: to)
            try Self.check(checkpoint)
        }

        let zip = work.appendingPathComponent("container.zip", isDirectory: false)
        try ArchiveEngine.zipDirectory(pack, to: zip, shouldKeepParent: false)
        try Self.check(checkpoint)
        try ArchiveSafetyValidator.validate(zip, destination: work.appendingPathComponent("check", isDirectory: true),
                                            limits: limits)

        // The export directory is retained by TemporaryCleanupPolicy until the
        // user-chosen document export finishes; only the work directory dies here.
        let exportDirectory = manager.uniqueTemporaryDirectory("VexContainerExport")
        try manager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let final = exportDirectory.appendingPathComponent(
            try ContainerPathPolicy.safeComponent(record.displayName) + ".vexcontainer", isDirectory: false
        )
        var encrypted = false
        if let password {
            guard password.count >= BackupPolicy.minimumPasswordLength else { throw ContainerArchiveError.passwordTooShort }
            try BackupCrypto.sealFile(zip, to: final, password: password)
            encrypted = true
        } else {
            try manager.moveItem(at: zip, to: final)
        }
        guard let digest = FileIntegrity.sha256(of: final) else { throw ContainerArchiveError.archiveInvalid }
        return ContainerExport(url: final, manifest: manifest, archiveSHA256: digest, isEncrypted: encrypted)
    }

    func exportDocument(id: String, password: String?) async -> ContainerArchiveFile? {
        let result: ContainerExport
        do { result = try await export(id: id, password: password) }
        catch { return nil }
        do { return ContainerArchiveFile(data: try Data(contentsOf: result.url)) }
        catch { return nil }
    }

    // MARK: - Inspect and restore

    func inspect(file: URL, password: String?) async throws -> ContainerExportManifest {
        let prepared = try await _plaintextArchive(file: file, password: password, workspacePrefix: "VexContainerPreview")
        defer { try? FileManager.default.removeItem(at: prepared.work) } // try? ok: preview staging cleanup
        return try _readManifest(from: prepared.archive)
    }

    func restore(
        file: URL,
        password: String?,
        authorization: ContainerRestoreAuthorization,
        checkpoint: (@Sendable () throws -> Void)? = nil
    ) async throws -> AppContainerRecord {
        try Self.check(checkpoint)
        let prepared = try await _plaintextArchive(file: file, password: password, workspacePrefix: "VexContainerRestore")
        defer { try? FileManager.default.removeItem(at: prepared.work) } // try? ok: restore staging cleanup
        try Self.check(checkpoint)

        try ArchiveSafetyValidator.validate(
            prepared.archive,
            destination: prepared.output,
            limits: limits,
            checkpoint: { try Self.check(checkpoint) }
        )
        let manifest = try _readManifest(from: prepared.archive)
        try Self.check(checkpoint)

        let archive = try Archive(url: prepared.archive, accessMode: .read)
        var extracted: [(relativePath: String, url: URL)] = []
        var seen = Set<String>()
        for entry in archive {
            try Self.check(checkpoint)
            let raw = entry.path.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let path = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            if entry.type == .directory {
                guard path == "Resources" || path.hasPrefix("Resources/") else { throw ContainerArchiveError.archiveInvalid }
                continue
            }
            guard path != "manifest.json" else { continue }
            guard path.hasPrefix("Resources/") else { throw ContainerArchiveError.archiveInvalid }
            let relative = String(path.dropFirst("Resources/".count))
            let safe = try ContainerPathPolicy.safeRelativePath(relative)
            guard manifest.container.resources.contains(where: { $0.relativePath == safe }),
                  seen.insert(safe).inserted else { throw ContainerArchiveError.archiveInvalid }
            let destination = prepared.output.appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(safe, isDirectory: false)
            guard ContainerPathPolicy.isContained(destination, in: prepared.output) else {
                throw ContainerArchiveError.archiveInvalid
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try archive.extract(entry, to: destination)
            try Self.check(checkpoint)
            extracted.append((safe, destination))
        }

        guard extracted.count == manifest.container.resources.count else { throw ContainerArchiveError.archiveInvalid }
        for resource in manifest.container.resources {
            guard let item = extracted.first(where: { $0.relativePath == resource.relativePath }) else {
                throw ContainerArchiveError.archiveInvalid
            }
            let values = try item.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? 0) == resource.byteCount,
                  try FileIntegrity.sha256(of: item.url) == resource.sha256 else {
                throw ContainerArchiveError.checksumMismatch(resource.relativePath)
            }
        }
        try Self.check(checkpoint)

        let forceID: String?
        switch authorization {
        case .createNew: forceID = nil
        case .replace(let id):
            guard id == manifest.container.id else { throw ContainerArchiveError.destinationExists }
            forceID = id
        }
        let heldOriginal: URL?
        if let replacementID = forceID {
            heldOriginal = try await store.detachForReplacement(id: replacementID)
        } else { heldOriginal = nil }
        do {
            var incoming = manifest.container
            incoming.state = .active
            incoming.runtimeHint = .none
            incoming.updatedAt = Date()
            let installed = try await store.installValidated(
                incoming, stagedResources: extracted, forceID: forceID,
                checkpoint: { try Self.check(checkpoint) }
            )
            try await store.commitReplacement(heldOriginal)
            return installed
        } catch {
            let restoreError = error
            if let forceID, let held = heldOriginal {
                do {
                    try await store.rollbackReplacement(held, id: forceID)
                } catch {
                    throw ContainerError.persistenceFailed(
                        "Restore failed (\(restoreError.localizedDescription)) and automatic recovery did not "
                            + "finish (\(error.localizedDescription)). Unresolved recovery data was retained."
                    )
                }
            }
            if restoreError is CancellationError { throw ContainerArchiveError.interrupted }
            throw restoreError
        }
    }

    // MARK: - Internals

    private static func check(_ checkpoint: (@Sendable () throws -> Void)?) throws {
        if let checkpoint { try checkpoint() } else { try Task.checkCancellation() }
    }

    private func _plaintextArchive(file: URL, password: String?, workspacePrefix: String) async throws -> (work: URL, archive: URL, output: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { throw ContainerArchiveError.archiveInvalid }
        let work = FileManager.default.uniqueTemporaryDirectory(workspacePrefix)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let archive = work.appendingPathComponent("input.zip", isDirectory: false)
            let output = work.appendingPathComponent("verified", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            if BackupCrypto.isEncrypted(file) {
                guard let password else { throw ContainerArchiveError.passwordRequired }
                guard password.count >= BackupPolicy.minimumPasswordLength else { throw ContainerArchiveError.passwordTooShort }
                _ = try BackupCrypto.unsealFile(file, to: archive, password: password)
            } else {
                try FileManager.default.copyItem(at: file, to: archive)
            }
            return (work, archive, output)
        } catch {
            try? FileManager.default.removeItem(at: work) // try? ok: failed setup cleanup
            throw error
        }
    }

    private func _readManifest(from archive: URL) throws -> ContainerExportManifest {
        let manager = FileManager.default
        let validationRoot = manager.uniqueTemporaryDirectory("VexContainerManifestCheck")
        try manager.createDirectory(at: validationRoot, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: validationRoot) } // try? ok: validation scratch cleanup
        try ArchiveSafetyValidator.validate(archive, destination: validationRoot, limits: limits)
        let zip = try Archive(url: archive, accessMode: .read)
        guard let entry = zip.first(where: { $0.path == "manifest.json" }) else {
            throw ContainerArchiveError.malformedManifest
        }
        let scratch = manager.uniqueTemporaryDirectory("VexContainerManifest")
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) } // try? ok: manifest scratch cleanup
        let url = scratch.appendingPathComponent("manifest.json", isDirectory: false)
        try zip.extract(entry, to: url)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: ContainerExportManifest
        do { manifest = try decoder.decode(ContainerExportManifest.self, from: data) }
        catch { throw ContainerArchiveError.malformedManifest }
        try manifest.validateFormat()
        var seenResources = Set<String>()
        for resource in manifest.container.resources {
            let safe = try ContainerPathPolicy.safeRelativePath(resource.relativePath)
            guard safe == resource.relativePath, seenResources.insert(safe).inserted else {
                throw ContainerArchiveError.malformedManifest
            }
        }
        return manifest
    }
}
