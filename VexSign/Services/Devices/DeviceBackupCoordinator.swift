// MARK: - Device application backup boundaries
//
// iOS does not let VexSign read another app's private sandbox, keychain or complete device
// backup. This service backs up only data VexSign owns: library records and metadata through
// the existing BackupManager, and selected VexSign-managed containers through the existing
// container archive service. An IPA is an installable package, not an application-data
// backup; that distinction is part of the model, not a footnote.

import Foundation
import NimbleExtensions

struct DeviceBackupExclusion: Equatable, Sendable, Identifiable {
    enum Reason: String, Equatable, Sendable {
        case thirdPartySandbox, keychain, heartbeat, systemData, ipaData
    }

    let reason: Reason
    let detail: String

    var id: String { reason.rawValue }
}

struct DeviceBackupScope: Equatable, Sendable {
    var includeLibraryMetadata: Bool = true
    var includeSources: Bool = false
    var includeSettings: Bool = false
    var includeTweaks: Bool = false
    var includeCertificates: Bool = false
    var containerIDs: [String] = []
    var password: String = ""

    var components: BackupComponents {
        var value: BackupComponents = []
        if includeLibraryMetadata { value.insert(.library) }
        if includeSources { value.insert(.sources) }
        if includeSettings { value.insert(.settings) }
        if includeTweaks { value.insert(.tweaks) }
        if includeCertificates { value.insert(.certificates) }
        return value
    }

    var exclusions: [DeviceBackupExclusion] {
        [
            .init(reason: .thirdPartySandbox,
                  detail: .localized("VexSign cannot read another application's private container or create a complete iOS device backup.")),
            .init(reason: .keychain,
                  detail: .localized("Other apps' keychain items are not accessible to VexSign.")),
            .init(reason: .ipaData,
                  detail: .localized("An IPA contains the app bundle, not the data that app created after installation.")),
            .init(reason: .systemData,
                  detail: .localized("iOS system data, device identifiers and pairing credentials are excluded by design."))
        ]
    }

    func validate() throws {
        guard containerIDs.count <= 64, containerIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw DeviceLifecycleError.invalidRecord
        }
        guard !includeCertificates || password.count >= BackupCrypto.minimumPasswordLength else {
            throw DeviceLifecycleError.operationBlocked(
                .localized("Backups containing certificates need a password of at least the required length.")
            )
        }
    }

    var summary: String {
        var parts: [String] = []
        if includeLibraryMetadata { parts.append(.localized("VexSign library records")) }
        if includeSources { parts.append(.localized("Sources")) }
        if includeSettings { parts.append(.localized("Settings")) }
        if includeTweaks { parts.append(.localized("Tweaks")) }
        if includeCertificates { parts.append(.localized("Certificates (encrypted)")) }
        if !containerIDs.isEmpty {
            parts.append(String.localized("%lld VexSign container(s)", arguments: containerIDs.count))
        }
        return parts.isEmpty ? .localized("Nothing selected") : parts.joined(separator: ", ")
    }
}

struct DeviceBackupResult: Equatable, Sendable {
    let archiveURL: URL
    let containerIDs: [String]
    let createdAt: Date
    let summary: String

    var message: String {
        String.localized(
            "VexSign data was backed up with the existing encrypted backup format. %lld VexSign container export(s) were produced separately. No third-party app data was read.",
            arguments: containerIDs.count
        )
    }
}

struct DeviceRestoreConflict: Equatable, Sendable, Identifiable {
    let bundleIdentifier: String
    let detail: String

    var id: String { bundleIdentifier }
}


enum DeviceRestoreConflictResolver {
    static func conflicts(archive: BackupArchiveSnapshot,
                          existingBundleIdentifiers: Set<String>) -> [DeviceRestoreConflict] {
        guard archive.contents.contains(.library) else { return [] }
        return existingBundleIdentifiers.sorted().map { identifier in
            DeviceRestoreConflict(bundleIdentifier: identifier,
                detail: .localized("An app with this bundle identifier is already in the Library. The restore keeps the existing record; it is not overwritten."))
        }
    }
}
protocol DeviceContainerArchiving: Sendable {
    func export(id: String, password: String?) async throws -> ContainerExport
    func inspect(file: URL, password: String?) async throws -> ContainerExportManifest
    func restore(file: URL, password: String?,
                 authorization: ContainerRestoreAuthorization) async throws -> AppContainerRecord
}

extension ContainerArchiveService: DeviceContainerArchiving {
    // The protocol witnesses take exactly the protocol's signature; the actor's
    // methods carry an extra defaulted checkpoint parameter that protocol
    // conformance cannot use, so these forward with no checkpoint.
    func export(id: String, password: String?) async throws -> ContainerExport {
        try await export(id: id, password: password, checkpoint: nil)
    }

    func restore(file: URL, password: String?,
                 authorization: ContainerRestoreAuthorization) async throws -> AppContainerRecord {
        try await restore(file: file, password: password, authorization: authorization, checkpoint: nil)
    }
}

@MainActor
final class DeviceBackupCoordinator {
    private let backups: BackupWorkspaceProviding
    private let containers: any DeviceContainerArchiving

    init(backups: BackupWorkspaceProviding, containers: any DeviceContainerArchiving) {
        self.backups = backups
        self.containers = containers
    }

    /// Backs up VexSign data with the app's own verified backup writer, then exports each
    /// selected VexSign-owned container. A failed container export does not delete the
    /// already-written main archive; the caller is told which container failed.
    func makeBackup(scope: DeviceBackupScope) async throws -> DeviceBackupResult {
        try scope.validate()
        try Task.checkCancellation()
        let archiveURL = try await backups.makeBackup(password: scope.password, components: scope.components)
        try Task.checkCancellation()

        var exported: [String] = []
        for id in scope.containerIDs {
            try Task.checkCancellation()
            _ = try await containers.export(id: id, password: scope.password.isEmpty ? nil : scope.password)
            exported.append(id)
        }
        return DeviceBackupResult(archiveURL: archiveURL, containerIDs: exported,
                                  createdAt: Date(), summary: scope.summary)
    }

    /// Preview of an existing VexSign backup, using the original open/verification path.
    @discardableResult
    func preview(file: URL, password: String) async throws -> BackupArchiveSnapshot {
        try await backups.open(file, password: password)
    }

    /// Preview of one VexSign container export. The manifest is validated before it is shown.
    @discardableResult
    func previewContainer(file: URL, password: String?) async throws -> ContainerExportManifest {
        let manifest = try await containers.inspect(file: file, password: password)
        try manifest.validateFormat()
        return manifest
    }

    /// Existing library records are retained by the restore engine. The conflict list says so
    /// explicitly; nothing is silently replaced.
    func conflicts(archive: BackupArchiveSnapshot, existingBundleIdentifiers: Set<String>) -> [DeviceRestoreConflict] {
        DeviceRestoreConflictResolver.conflicts(archive: archive, existingBundleIdentifiers: existingBundleIdentifiers)
    }

    @discardableResult
    func restore(archiveID: UUID, components: BackupComponents) async throws -> BackupRestoreSummary {
        try await backups.restore(archiveID: archiveID, components: components)
    }

    @discardableResult
    func restoreContainer(file: URL, password: String?,
                          authorization: ContainerRestoreAuthorization) async throws -> AppContainerRecord {
        let manifest = try await containers.inspect(file: file, password: password)
        try manifest.validateFormat()
        return try await containers.restore(file: file, password: password, authorization: authorization)
    }
}
