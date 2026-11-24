import Foundation
import CoreData
import Combine

/// Resolves opaque identities back to this store, on its owning queue. Supplying an
/// old or foreign store ID is never permission to guess a different row by UUID.
extension Storage {
    func managedApp(matching reference: LibraryAppReference) throws -> AppInfoPresentable {
        StorageConcurrency.requireMainQueue()
        let expected = reference.isSigned ? "Signed" : "Imported"
        let object: NSManagedObject
        if let opaqueID = reference.recordID {
            guard let uri = URL(string: opaqueID),
                  let id = container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: uri),
                  id.entity.name == expected, !id.isTemporaryID else { throw WorkspaceAccessError.mismatchedRecord }
            object = try context.existingObject(with: id)
        } else {
            let request = NSFetchRequest<NSManagedObject>(entityName: expected)
            request.predicate = NSPredicate(format: "uuid == %@", reference.uuid)
            request.fetchLimit = 2
            let rows = try context.fetch(request)
            guard rows.count == 1, let row = rows.first else { throw WorkspaceAccessError.missingRecord }
            object = row
        }
        guard !object.isDeleted, let app = object as? AppInfoPresentable,
              app.uuid == reference.uuid, app.isSigned == reference.isSigned else { throw WorkspaceAccessError.mismatchedRecord }
        return app
    }

    func managedCertificate(id: String) throws -> CertificatePair {
        StorageConcurrency.requireMainQueue()
        guard let uri = URL(string: id),
              let objectID = container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: uri),
              objectID.entity.name == "CertificatePair", !objectID.isTemporaryID,
              let certificate = try context.existingObject(with: objectID) as? CertificatePair,
              !certificate.isDeleted else { throw WorkspaceAccessError.missingRecord }
        return certificate
    }

    func managedRepository(id: String) throws -> AltSource {
        StorageConcurrency.requireMainQueue()
        guard let uri = URL(string: id),
              let objectID = container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: uri),
              objectID.entity.name == "AltSource", !objectID.isTemporaryID,
              let source = try context.existingObject(with: objectID) as? AltSource,
              !source.isDeleted else { throw WorkspaceAccessError.missingRecord }
        return source
    }
}

@MainActor
final class CoreDataWorkspaceRepository: WorkspaceCatalogProviding, LibraryRepository {
    let storage: Storage
    init(storage: Storage) { self.storage = storage }

    func readWorkspace() throws -> WorkspaceSnapshot {
        // Throwing reads: a store that cannot be read must say so. Flattening the failure into
        // "no rows" renders an empty library, which is indistinguishable from one where nothing
        // was ever imported. `WorkspaceViewModel.loadError` shows this sentence.
        let signed = try storage.fetchOnQueueThrowing(Signed.fetchRequest())
        let imported = try storage.fetchOnQueueThrowing(Imported.fetchRequest())
        let certificateRequest = CertificatePair.fetchRequest()
        certificateRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
        let certificates = try storage.fetchOnQueueThrowing(certificateRequest)
        let sources = try storage.fetchOnQueueThrowing(AltSource.fetchRequest())
        return WorkspaceSnapshot(
            signedApps: try signed.map { try appRecord($0) },
            importedApps: try imported.map { try appRecord($0) },
            certificates: certificates.map(certificateRecord),
            repositories: sources.map(repositoryRecord)
        )
    }

    func workspaceChanges() -> AsyncStream<Void> {
        let context = storage.context
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextObjectsDidChange, object: context, queue: .main
            ) { _ in
                // Leave the context notification before fetching, and let a transaction's
                // insert/update/merge notifications coalesce into a single snapshot.
                Task { @MainActor in
                    continuation.yield(Void())
                }
            }
            let observation = StreamObservationCancellation(AnyCancellable { NotificationCenter.default.removeObserver(token) })
            continuation.onTermination = { _ in observation.cancel() }
        }
    }

    /// Every production/result projection uses the same admission gate, including
    /// statically typed Signed/Imported values. A typed overload must not bypass
    /// this check and fault relationships from another context or a retired row.
    func appRecord(_ app: AppInfoPresentable) throws -> LibraryAppRecord {
        guard let row = app as? NSManagedObject, row.managedObjectContext === storage.context,
              !row.isDeleted, !row.objectID.isTemporaryID else { throw WorkspaceAccessError.mismatchedRecord }
        if let signed = app as? Signed {
            return appRecord(signed, sortIndex: signed.sortIndex, source: signed.source, certificate: signed.certificate)
        }
        if let imported = app as? Imported {
            return appRecord(imported, sortIndex: imported.sortIndex, source: imported.source, certificate: nil)
        }
        throw WorkspaceAccessError.invalidReference
    }

    private func appRecord(_ app: AppInfoPresentable, sortIndex: Int32, source: URL?, certificate: CertificatePair?) -> LibraryAppRecord {
        LibraryAppRecord(id: app.recordID ?? "", uuid: app.uuid, isSigned: app.isSigned,
                         name: app.name, version: app.version, identifier: app.identifier,
                         originalIdentifier: app.originalIdentifier, date: app.date, icon: app.icon,
                         appDescription: app.appDescription, sortIndex: sortIndex, source: source,
                         certificateID: certificate?.objectID.uriRepresentation().absoluteString,
                         bundleURL: storage.getAppDirectory(for: app), artifactURL: storage.getUuidDirectory(for: app))
    }

    func certificateRecord(_ cert: CertificatePair) -> CertificateRecord {
        CertificateRecord(id: cert.objectID.uriRepresentation().absoluteString, uuid: cert.uuid,
                          nickname: cert.nickname, date: cert.date, expiration: cert.expiration,
                          isDefault: cert.isDefault, ppQCheck: cert.ppQCheck, revoked: cert.revoked,
                          profile: storage.getProvisionFileDecoded(for: cert),
                          additionalProfilePatterns: AdditionalProfiles.patterns(for: cert))
    }

    func repositoryRecord(_ source: AltSource) -> RepositoryRecord {
        RepositoryRecord(id: source.objectID.uriRepresentation().absoluteString, name: source.name,
                         identifier: source.identifier, sourceURL: source.sourceURL, iconURL: source.iconURL, date: source.date)
    }

    func importPackage(_ source: URL) async throws -> LibraryAppRecord {
        try Task.checkCancellation()
        let cancellation = BackgroundWorkCancellation()
        let app = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AppInfoPresentable, Error>) in
                let worker = PackageImportService.importPackage(source) { result in continuation.resume(with: result) }
                cancellation.adopt(worker)
            }
        } onCancel: { cancellation.cancel() }
        // A committed import remains a registered artifact even if its initiating
        // screen disappears. Only the immutable projection crosses back to UI.
        guard let row = app as? NSManagedObject, row.managedObjectContext === storage.context else {
            throw WorkspaceAccessError.mismatchedRecord
        }
        return try appRecord(app)
    }

    func bundleURL(for reference: LibraryAppReference) -> URL? {
        guard let app = try? storage.managedApp(matching: reference) else { return nil } // try? ok: optional lookup refuses stale or foreign records rather than guessing
        return storage.getAppDirectory(for: app)
    }

    func artifactURL(for reference: LibraryAppReference) -> URL? {
        guard let app = try? storage.managedApp(matching: reference) else { return nil } // try? ok: optional lookup refuses stale or foreign records rather than guessing
        return storage.getUuidDirectory(for: app)
    }

    func certificate(for reference: LibraryAppReference) -> CertificateRecord? {
        guard let app = try? storage.managedApp(matching: reference), // try? ok: optional lookup refuses stale or foreign records rather than guessing
              let certificate = storage.getCertificate(from: app) else { return nil }
        return certificateRecord(certificate)
    }

    func deleteApps(_ references: [LibraryAppReference]) throws {
        let rows = try references.map { try storage.managedApp(matching: $0) }
        guard storage.deleteApps(rows) else { throw WorkspaceAccessError.persistenceFailed }
    }

    func renameApp(_ reference: LibraryAppReference, name: String) throws {
        try update([reference]) { _, row in row.setValue(name, forKey: "name") }
    }

    func describeApp(_ reference: LibraryAppReference, description: String?) throws {
        try update([reference]) { _, row in row.setValue(description, forKey: "appDescription") }
    }

    func reorderApps(_ references: [LibraryAppReference]) throws {
        try update(references) { index, row in row.setValue(Int32(index), forKey: "sortIndex") }
    }

    func renameCertificate(id: String, nickname: String?) throws {
        let row = try storage.managedCertificate(id: id)
        try update(ids: [row.objectID]) { _, row in row.setValue(nickname, forKey: "nickname") }
    }

    /// Isolated saves cannot accidentally commit or roll back an unrelated view edit.
    private func update(_ references: [LibraryAppReference], change: (Int, NSManagedObject) -> Void) throws {
        let ids = try references.map { reference -> NSManagedObjectID in
            guard let object = try storage.managedApp(matching: reference) as? NSManagedObject else {
                throw WorkspaceAccessError.missingRecord
            }
            return object.objectID
        }
        try update(ids: ids, change: change)
    }

    private func update(ids: [NSManagedObjectID], change: (Int, NSManagedObject) -> Void) throws {
        guard !ids.isEmpty else { return }
        let transaction = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        transaction.persistentStoreCoordinator = storage.container.persistentStoreCoordinator
        transaction.mergePolicy = NSErrorMergePolicy
        do {
            let rows = try ids.map { try transaction.existingObject(with: $0) }
            for (index, row) in rows.enumerated() { change(index, row) }
            try transaction.save()
        } catch {
            transaction.rollback()
            throw error
        }
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSUpdatedObjectsKey: ids], into: [storage.context])
    }
}
