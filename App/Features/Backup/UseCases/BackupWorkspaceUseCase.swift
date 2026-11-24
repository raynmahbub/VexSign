import Foundation

/// Serializes this feature's requests, without a second backup implementation.
@MainActor
final class BackupWorkspaceUseCase {
    private let provider: BackupWorkspaceProviding
    private var working = false
    init(provider: BackupWorkspaceProviding) { self.provider = provider }
    func availableComponents() -> BackupAvailability { provider.availableComponents() }
    func protection(of url: URL) async throws -> BackupImportProtection { try await provider.protection(of: url) }
    func makeBackup(password: String, components: BackupComponents) async throws -> URL {
        guard !working else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        working = true; defer { working = false }
        try Task.checkCancellation()
        return try await provider.makeBackup(password: password, components: components)
    }
    func open(_ url: URL, password: String) async throws -> BackupArchiveSnapshot {
        guard !working else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        working = true; defer { working = false }
        try Task.checkCancellation()
        let preview = try await provider.open(url, password: password)
        if Task.isCancelled { provider.release(archiveID: preview.id); throw CancellationError() }
        return preview
    }
    func restore(_ preview: BackupArchiveSnapshot, components: BackupComponents) async throws -> BackupRestoreSummary {
        guard !working else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        guard !components.isEmpty, components.subtracting(preview.contents).isEmpty else { throw WorkspaceAccessError.invalidReference }
        working = true; defer { working = false }
        try Task.checkCancellation()
        return try await provider.restore(archiveID: preview.id, components: components)
    }
    func release(archiveID: UUID) { provider.release(archiveID: archiveID) }
}
