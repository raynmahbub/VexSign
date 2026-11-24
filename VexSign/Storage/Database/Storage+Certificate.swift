//
//  Storage+Certificate.swift
//  VexSign
//
//  Created by VexSign Contributors on 16.04.2025.
//

import CoreData
import OSLog

// MARK: - Class extension: certificate
extension Storage {
    @MainActor
    func addCertificate(
        uuid: String,
        password: String? = nil,
        nickname: String? = nil,
        ppq: Bool = false,
        expiration: Date,
        isDefault: Bool = false,
        date: Date? = Date(),
        revoked: Bool = false,
        relinkingSignedAppURIs: [URL] = [],
        saveCertificate: (NSManagedObjectContext) throws -> Void = { try $0.save() },
        completion: @escaping (Error?) -> Void
    ) {
        StorageConcurrency.requireMainQueue()
        let transaction = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        transaction.persistentStoreCoordinator = container.persistentStoreCoordinator
        transaction.mergePolicy = NSErrorMergePolicy
        let account = SecureSecretStore.certificatePasswordAccount(uuid)
        var wrotePassword = false
        do {
            guard UUID(uuidString: uuid) != nil else { throw WorkspaceAccessError.invalidReference }
            let existing = CertificatePair.fetchRequest()
            existing.predicate = NSPredicate(format: "uuid ==[c] %@", uuid)
            existing.fetchLimit = 1
            guard try context.fetch(existing).isEmpty, try transaction.count(for: existing) == 0 else { throw WorkspaceAccessError.mismatchedRecord }
            try SecureSecretStore.write(Data((password ?? "").utf8), account: account)
            wrotePassword = true
            let new = CertificatePair(context: transaction)
            new.uuid = uuid
            new.date = date
            new.password = nil
            new.ppQCheck = ppq
            new.expiration = expiration
            new.nickname = nickname
            new.isDefault = isDefault
            new.revoked = revoked
            var relinked: [NSManagedObjectID] = []
            for uri in relinkingSignedAppURIs {
                guard let id = container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: uri),
                      id.entity.name == "Signed", !id.isTemporaryID else { continue }
                // Deleted app rows and independently re-linked apps are not overwritten.
                let fetch = Signed.fetchRequest()
                fetch.predicate = NSPredicate(format: "SELF == %@", id)
                fetch.fetchLimit = 1
                if let row = try transaction.fetch(fetch).first, row.certificate == nil {
                    row.certificate = new
                    relinked.append(id)
                }
            }
            try saveCertificate(transaction)
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSInsertedObjectsKey: [new.objectID],
                NSUpdatedObjectsKey: relinked], into: [context])
        } catch {
            transaction.rollback()
            if wrotePassword {
                do { try SecureSecretStore.delete(account) }
                catch { Logger.misc.error("Could not remove a failed certificate import's Keychain item.") }
            }
            completion(error)
            return
        }
        Task { @MainActor in
            await Task.yield()
            WidgetStatusPublisher.publish(includeRepository: false)
        }
        Haptics.lightImpact()
        Task { await AnalyticsStore.shared.record(.certificatesAdded) }
        completion(nil)
    }

    /// Commit row/relationship deletion first in an isolated context. A failed
    /// save cannot erase a surviving row's password/files or unrelated view edits.
    /// Cleanup failures after commit remain logged, recoverable orphan material.
    @MainActor
    @discardableResult
    func deleteCertificate(for cert: CertificatePair) -> Bool {
        deleteCertificate(for: cert, saveDeletion: { try $0.save() })
    }

    @MainActor
    @discardableResult
    func deleteCertificate(for cert: CertificatePair, saveDeletion: (NSManagedObjectContext) throws -> Void) -> Bool {
        StorageConcurrency.requireMainQueue()
        guard cert.managedObjectContext === context, !cert.isDeleted, !cert.objectID.isTemporaryID,
              let uuid = cert.uuid, UUID(uuidString: uuid) != nil else { return false }
        guard !AppOperationRegistry.shared.isBusy(SigningIdentityStore.leaseKey(reference: cert.objectID.uriRepresentation().absoluteString)) else { return false }
        let id = cert.objectID
        let directory = getUuidDirectory(for: cert)
        let linkedIDs = ((cert.signedApps as? Set<Signed>) ?? []).map(\.objectID)
        let deletion = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        deletion.persistentStoreCoordinator = container.persistentStoreCoordinator
        deletion.mergePolicy = NSErrorMergePolicy
        do {
            let request = CertificatePair.fetchRequest()
            request.predicate = NSPredicate(format: "SELF == %@", id)
            request.fetchLimit = 1
            guard let row = try deletion.fetch(request).first else { return false }
            deletion.delete(row)
            try saveDeletion(deletion)
        } catch {
            deletion.rollback()
            Logger.misc.error("Certificate deletion could not be saved; credential and files retained.")
            return false
        }
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: [id],
            NSUpdatedObjectsKey: linkedIDs], into: [context])
        do { try SecureSecretStore.delete(SecureSecretStore.certificatePasswordAccount(uuid)) }
        catch { Logger.misc.error("Could not remove certificate Keychain item; cleanup requires an unlocked Keychain.") }
        if let directory {
            let root = directory.deletingLastPathComponent()
            do {
                guard Self.allowedCertificateDeletionOriginal(directory) else { throw CleanupRemovalPolicy.Rejection.unsafeTarget }
                _ = try CleanupRemovalPolicy.remove(directory, beneath: root)
            } catch {
                Logger.misc.error("Could not delete certificate files; the private key remains until Remove Leftovers runs.")
            }
        }
        // Retire old checks before a synchronous Undo/new import can start a
        // new generation using the same UUID. No queued invalidation may kill it.
        CertificateStatusManager.shared.removeRevocationSnapshot(certificateUUID: uuid)
        WidgetStatusPublisher.publish()
        return true
    }

    static var certificateDeletionRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingCertificateDeletions", isDirectory: true)
    }

    static func prepareCertificateDeletionRoot() throws -> URL {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        if !fileManager.fileExists(atPath: support.path) {
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        }
        guard CleanupRemovalPolicy.isSafeDirectory(support, beneath: library) else {
            throw CleanupRemovalPolicy.Rejection.unsafeTarget
        }
        if !fileManager.fileExists(atPath: certificateDeletionRoot.path) {
            try fileManager.createDirectory(at: certificateDeletionRoot, withIntermediateDirectories: false)
        }
        guard CleanupRemovalPolicy.isSafeDirectory(certificateDeletionRoot, beneath: support) else {
            throw CleanupRemovalPolicy.Rejection.unsafeTarget
        }
        return certificateDeletionRoot
    }

    static func allowedCertificateDeletionOriginal(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let path = url.standardizedFileURL
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let roots = [
            support.appendingPathComponent("Private/Certificates", isDirectory: true),
            URL.documentsDirectory.appendingPathComponent("Certificates", isDirectory: true)
        ]
        guard path.isFileURL, UUID(uuidString: path.lastPathComponent) != nil,
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let root = roots.first(where: { $0.standardizedFileURL.path == path.deletingLastPathComponent().path }),
              [support, URL.documentsDirectory].contains(where: { CleanupRemovalPolicy.isSafeDirectory(root, beneath: $0) }) else { return false }
        do {
            let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return true
        } catch {
            return false
        }
        return CleanupRemovalPolicy.isSafeTarget(path, beneath: root)
    }

    /// Read both persisted identities and pending view inserts. A pending view
    /// deletion is not evidence that the committed owner is gone. A replacement
    /// row with a different object ID but the same UUID also owns this path.
    func containsCertificateIdentity(uuid: String) throws -> Bool {
        StorageConcurrency.requireMainQueue()
        guard UUID(uuidString: uuid) != nil else { throw WorkspaceAccessError.invalidReference }
        guard !container.persistentStoreCoordinator.persistentStores.isEmpty else { throw WorkspaceAccessError.persistenceFailed }
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = container.persistentStoreCoordinator
        let request = CertificatePair.fetchRequest()
        request.predicate = NSPredicate(format: "uuid ==[c] %@", uuid)
        request.includesPendingChanges = false
        let committed = try reader.count(for: request) > 0
        request.includesPendingChanges = true
        let pending = try context.count(for: request) > 0
        return committed || pending
    }

    /// Also covers interruption after restoring bytes but before inserting the
    /// replacement row, and a failed attempt to re-stage those bytes. The journal
    /// is not dropped until both staged and unowned original copies are erased.
    func recoverCertificateDeletion(_ transaction: StagedAppDeletion) throws {
        StorageConcurrency.requireMainQueue()
        guard transaction.entries.count == 1, let entry = transaction.entries.first,
              Self.allowedCertificateDeletionOriginal(entry.original),
              let id = container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: entry.objectURI),
              id.entity.name == "CertificatePair" else { throw WorkspaceAccessError.invalidReference }
        let ownerExists = try containsCertificateIdentity(uuid: entry.original.lastPathComponent)
        try transaction.recover(rowExists: { _ in ownerExists }, allowedOriginal: Self.allowedCertificateDeletionOriginal,
            removingUnownedOriginals: true)
    }

    /// A failed rollback is not a disposable RemovedItems offer. Durable journals
    /// survive process exit and retain files whenever the store cannot be read.
    func recoverPendingCertificateDeletions() {
        StorageConcurrency.requireMainQueue()
        guard let lease = AppOperationRegistry.shared.acquireCleanup() else { return }
        defer { withExtendedLifetime(lease) {} }
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        guard fileManager.fileExists(atPath: Self.certificateDeletionRoot.path) else { return }
        guard CleanupRemovalPolicy.isSafeDirectory(support, beneath: library),
              CleanupRemovalPolicy.isSafeDirectory(Self.certificateDeletionRoot, beneath: support) else {
            Logger.misc.error("Certificate deletion journal path is unsafe; no private files changed.")
            return
        }
        do {
            for directory in try fileManager.contentsOfDirectory(at: Self.certificateDeletionRoot, includingPropertiesForKeys: nil) {
                guard CleanupRemovalPolicy.isSafeDirectory(directory, beneath: Self.certificateDeletionRoot) else {
                    Logger.misc.error("Unsafe certificate deletion journal entry retained.")
                    continue
                }
                do {
                    let transaction = try StagedAppDeletion(directory: directory)
                    try recoverCertificateDeletion(transaction)
                } catch { Logger.misc.error("Certificate deletion recovery deferred; tracked private files retained.") }
            }
        } catch { Logger.misc.error("Certificate deletion recovery is unavailable; no private files changed.") }
    }

	func getCertificate(for index: Int) -> CertificatePair? {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]

		let results = fetchOnQueue(fetchRequest)
		guard index >= 0 && index < results.count else {
			return nil
		}

		return results[index]
	}

    /// Compatibility entry point for certificate-list and auto-import callers.
    /// Never call Zsign.checkRevokage here: its native async OCSP implementation
    /// holds dangling certificate state and parses into an uninitialized pointer.
    @MainActor
    func revokagedCertificate(for cert: CertificatePair, completion: ((Bool) -> Void)? = nil) {
        guard !cert.isDeleted, cert.managedObjectContext === context, !cert.objectID.isTemporaryID else {
            completion?(false)
            return
        }
        guard !cert.revoked else { completion?(true); return }
        guard let uuid = cert.uuid,
              let p12 = getFile(.certificate, from: cert),
              let profile = getFile(.provision, from: cert),
              let password = cert.signingPassword else {
            completion?(false)
            return
        }
        let name = cert.nickname ?? "Certificate"

        // Capture all needed data before the async work to avoid retaining the managed object
        let certUUID = uuid
        let certObjectID = cert.objectID
        let certP12 = p12
        let certProfile = profile
        let certPassword = password
        let certName = name

        Task {
            do {
                let health = try await CertificateInspector.inspect(
                    id: certUUID, name: certName, p12: certP12, password: certPassword, profile: certProfile, online: true
                )
                // Re-fetch the certificate to ensure it still exists and is valid
                await MainActor.run {
                    guard !Task.isCancelled, let refreshedCert = self._certificate(objectID: certObjectID, uuid: certUUID),
                          !refreshedCert.isDeleted,
                          refreshedCert.managedObjectContext != nil else {
                        completion?(false)
                        return
                    }
                    if health.revocation == .revoked {
                        refreshedCert.revoked = true
                        self.saveContext()
                    }
                    completion?(refreshedCert.revoked)
                }
            } catch {
                // Offline, malformed or unverifiable evidence is unknown, not revoked.
                FileLogger.log("Certificate status check could not complete: \(error)", category: "certificate")
                await MainActor.run { completion?(false) }
            }
        }
    }

    @MainActor
    private func _certificate(objectID: NSManagedObjectID, uuid: String) -> CertificatePair? {
        let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "SELF == %@ AND uuid == %@", objectID, uuid)
        fetchRequest.fetchLimit = 1
        return fetchOnQueue(fetchRequest).first
    }

	enum FileRequest: String {
		case certificate = "p12"
		case provision = "mobileprovision"
	}

	func getFile(_ type: FileRequest, from cert: CertificatePair) -> URL? {
		guard let url = getUuidDirectory(for: cert) else {
			return nil
		}

		return FileManager.default.getPath(in: url, for: type.rawValue)
	}

	func getProvisionFileDecoded(for cert: CertificatePair) -> Certificate? {
		guard let url = getFile(.provision, from: cert) else {
			return nil
		}

		let read = CertificateReader(url)
		return read.decoded
	}

	func getUuidDirectory(for cert: CertificatePair) -> URL? {
		guard let uuid = cert.uuid else {
			return nil
		}

		return FileManager.default.certificates(uuid)
	}

	func getAllCertificates() -> [CertificatePair] {
		let fetchRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
		return fetchOnQueue(fetchRequest)
	}

	@MainActor
	func relinkSignedApps(objectURIs: [URL], to certificate: CertificatePair) {
		StorageConcurrency.requireMainQueue()
		guard let coordinator = container.persistentStoreCoordinator as NSPersistentStoreCoordinator? else { return }
		for uri in objectURIs {
			guard let objectID = coordinator.managedObjectID(forURIRepresentation: uri) else { continue }
			do {
				if let app = try context.existingObject(with: objectID) as? Signed, !app.isDeleted, app.certificate == nil {
					app.certificate = certificate
				}
			} catch {
				// The app row was deleted while the undo window was open.
				continue
			}
		}
		saveContext()
	}
}
