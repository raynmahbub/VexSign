import Foundation

@MainActor
final class BackupWorkspaceAdapter: BackupWorkspaceProviding {
    private let manager: BackupManager
    private var opened: [UUID: BackupArchive] = [:]
    init(manager: BackupManager) { self.manager = manager }
    func availableComponents() -> BackupAvailability {
        let value = manager.availableComponents()
        return BackupAvailability(components: value.components, counts: value.counts)
    }
    func protection(of url: URL) async throws -> BackupImportProtection {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close() // Unreadable input is not inferred to be plaintext.
            if BackupCrypto.isLegacyPlaintext(url) { return BackupImportProtection.legacyPlaintext }
            return BackupCrypto.needsPassword(url) ? .password : .deviceOnly
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }
    func makeBackup(password: String, components: BackupComponents) async throws -> URL {
        try await manager.makeBackup(password: password, components: components)
    }
    func open(_ url: URL, password: String) async throws -> BackupArchiveSnapshot {
        guard opened.isEmpty else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let archive = try await manager.open(url, password: password)
        try Task.checkCancellation()
        opened[archive.id] = archive
        return BackupArchiveSnapshot(id: archive.id, createdAt: archive.manifest.createdAt,
            appVersion: archive.manifest.appVersion, schemaVersion: archive.manifest.version,
            contents: archive.contents,
            counts: BackupComponents.ordered.reduce(into: [:]) { $0[$1] = archive.manifest.count(of: $1) },
            integrity: archive.integrity)
    }
    func restore(archiveID: UUID, components: BackupComponents) async throws -> BackupRestoreSummary {
        guard let archive = opened[archiveID], components.subtracting(archive.contents).isEmpty else { throw WorkspaceAccessError.invalidReference }
        defer { opened.removeValue(forKey: archiveID) }
        return try await manager.restore(archive, components: components)
    }
    func release(archiveID: UUID) { opened.removeValue(forKey: archiveID) }
}
