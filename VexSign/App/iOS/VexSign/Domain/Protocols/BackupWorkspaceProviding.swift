import Foundation

@MainActor
protocol BackupWorkspaceProviding: AnyObject {
    func availableComponents() -> BackupAvailability
    func protection(of url: URL) async throws -> BackupImportProtection
    func makeBackup(password: String, components: BackupComponents) async throws -> URL
    func open(_ url: URL, password: String) async throws -> BackupArchiveSnapshot
    func restore(archiveID: UUID, components: BackupComponents) async throws -> BackupRestoreSummary
    func release(archiveID: UUID)
}
