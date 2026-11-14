import Foundation

@MainActor
final class LibraryUseCase {
    private let repository: LibraryRepository
    private let cloning: LibraryCloningProviding
    init(repository: LibraryRepository, cloning: LibraryCloningProviding) { self.repository = repository; self.cloning = cloning }
    func importPackage(_ source: URL) async throws -> LibraryAppRecord {
        try Task.checkCancellation()
        guard source.isFileURL, ["ipa", "tipa"].contains(source.pathExtension.lowercased()) else {
            throw WorkspaceAccessError.invalidReference
        }
        return try await repository.importPackage(source)
    }
    func clone(_ app: AppInfoPresentable, request: LibraryCloneRequest) async throws -> LibraryAppRecord {
        try Task.checkCancellation()
        return try await cloning.clone(LibraryAppReference(app: app), request: request)
    }

    func bundleURL(for app: AppInfoPresentable) -> URL? {
        guard let reference = try? LibraryAppReference(app: app) else { return nil } // try? ok: optional display lookup fails closed for an invalid library identity
        return repository.bundleURL(for: reference)
    }

    func artifactURL(for app: AppInfoPresentable) -> URL? {
        guard let reference = try? LibraryAppReference(app: app) else { return nil } // try? ok: optional display lookup fails closed for an invalid library identity
        return repository.artifactURL(for: reference)
    }

    func certificate(for app: AppInfoPresentable) -> CertificateRecord? {
        guard let reference = try? LibraryAppReference(app: app) else { return nil } // try? ok: optional display lookup fails closed for an invalid library identity
        return repository.certificate(for: reference)
    }

    func delete(_ apps: [AppInfoPresentable]) throws {
        // Resolve the whole selection first. A stale/malformed member must not delete
        // a different artifact or silently turn an all-or-nothing command into a subset.
        let references = try apps.map { try LibraryAppReference(app: $0) }
        try repository.deleteApps(references)
    }

    func rename(_ app: AppInfoPresentable, to name: String) throws {
        try repository.renameApp(try LibraryAppReference(app: app), name: name)
    }

    func setDescription(_ description: String?, for app: AppInfoPresentable) throws {
        try repository.describeApp(try LibraryAppReference(app: app), description: description)
    }

    func reorder(_ apps: [AppInfoPresentable]) throws {
        let references = try apps.map { try LibraryAppReference(app: $0) }
        guard references.count <= Int(Int32.max), Set(references).count == references.count,
              Set(references.map(\.isSigned)).count <= 1 else { throw WorkspaceAccessError.invalidOrder }
        try repository.reorderApps(references)
    }
}
