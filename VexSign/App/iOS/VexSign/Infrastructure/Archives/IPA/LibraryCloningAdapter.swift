import Foundation

@MainActor
final class LibraryCloningAdapter: LibraryCloningProviding {
    private let repository: CoreDataWorkspaceRepository
    private let cloner: AppCloner
    init(repository: CoreDataWorkspaceRepository, cloner: AppCloner) { self.repository = repository; self.cloner = cloner }
    func clone(_ source: LibraryAppReference, request: LibraryCloneRequest) async throws -> LibraryAppRecord {
        try Task.checkCancellation()
        let row = try repository.storage.managedApp(matching: source)
        let snapshot = try repository.appRecord(row)
        return try repository.appRecord(try await cloner.clone(app: snapshot, customName: request.customName,
            customBundleId: request.customBundleIdentifier, asUnsigned: request.asUnsigned, iconOrdinal: request.iconOrdinal))
    }
}
