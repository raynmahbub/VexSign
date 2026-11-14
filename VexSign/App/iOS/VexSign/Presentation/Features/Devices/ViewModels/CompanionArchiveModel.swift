import Foundation

@MainActor
final class CompanionArchiveModel {
    private let useCase: CompanionArchiveUseCase
    init(useCase: CompanionArchiveUseCase) { self.useCase = useCase }
    func prepareLibrary(_ app: AppInfoPresentable, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try await useCase.prepareLibrary(app, progress: progress)
    }
    func stage(_ source: URL) async throws -> URL { try await useCase.stage(source) }
    func prepareEmbeddedImport(_ stagedURL: URL) async throws -> Bool {
        try Task.checkCancellation()
        return try await useCase.prepareEmbeddedImport(stagedURL)
    }
    func share(_ stagedURL: URL) throws { try useCase.share(stagedURL) }
    func remove(_ stagedURL: URL) throws { try useCase.remove(stagedURL) }
}
