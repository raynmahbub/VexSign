import Foundation

/// Preparing a companion file neither signs it nor proves installation/import.
@MainActor
final class CompanionArchiveUseCase {
    private let provider: CompanionArchivePreparing
    init(provider: CompanionArchivePreparing) { self.provider = provider }
    func prepareLibrary(_ app: AppInfoPresentable, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try await provider.prepareLibrary(LibraryAppReference(app: app), progress: progress)
    }
    func stage(_ source: URL) async throws -> URL {
        guard source.pathExtension.lowercased() == "ipa" else { throw WorkspaceAccessError.invalidReference }
        return try await provider.stage(source)
    }
    func prepareEmbeddedImport(_ stagedURL: URL) async throws -> Bool {
        try Task.checkCancellation()
        return try await provider.prepareEmbeddedImport(stagedURL)
    }
    func share(_ stagedURL: URL) throws { try provider.share(stagedURL) }
    func remove(_ stagedURL: URL) throws { try provider.remove(stagedURL) }
}
