import Foundation
import CoreData
import OSLog
import NimbleExtensions

// MARK: - Certificates

/// Deletes a certificate while keeping what is needed to put it back for a few seconds.
///
/// The certificate really is deleted — row, Keychain password, revocation snapshot — so
/// nothing can sign with it during the offer. Its folder (the .p12 and profiles) is moved
/// aside rather than erased, and the password is kept in memory only. When the offer ends
/// the folder is erased; if the app is closed first, the durable launch recovery purges it only after confirming its row is absent.
enum CertificateRemoval {
	struct Snapshot {
		let uuid: String
		let nickname: String?
		let ppq: Bool
		let expiration: Date
		let isDefault: Bool
		let revoked: Bool
		let date: Date?
		let password: String
		let signedAppURIs: [URL]
	}

    @MainActor
    @discardableResult
	static func delete(_ cert: CertificatePair, storage: Storage = .shared,
        saveDeletion: (NSManagedObjectContext) throws -> Void = { try $0.save() },
        saveRestoration: @escaping (NSManagedObjectContext) throws -> Void = { try $0.save() }) -> Bool {
        guard cert.managedObjectContext === storage.context, !cert.isDeleted, !cert.objectID.isTemporaryID else { return false }
        guard !AppOperationRegistry.shared.isBusy(SigningIdentityStore.leaseKey(reference: cert.objectID.uriRepresentation().absoluteString)) else {
            Toast.info("This identity or one of its profiles is in use by a signing run. Wait for it to finish before deleting it.")
            return false
        }
        let offer: (Snapshot, StagedAppDeletion?)?
        do { offer = try _prepareUndo(for: cert, storage: storage) }
        catch {
            // A partial holding move is not permission to commit deletion.
            // Its durable journal keeps rollback/recovery ownership if I/O fails.
            Toast.error(error.localizedDescription)
            return false
        }
        guard storage.deleteCertificate(for: cert, saveDeletion: saveDeletion) else {
            // The surviving row still owns its files/password. Roll back only
            // this holding move; never announce an Undo for an uncommitted delete.
            if let token = offer?.1 {
                do { try token.recover(rowExists: { _ in true }, allowedOriginal: Storage.allowedCertificateDeletionOriginal) }
                catch { Logger.misc.error("Certificate deletion failed; durable rollback journal retained for recovery.") }
            }
            return false
        }
		guard let (snapshot, token) = offer else { return true }

		UndoableRemoval.announce(UndoableRemoval(
			title: snapshot.nickname ?? .localized("Certificate"),
			// The operation lease enforces the main-thread undo deadline independently of the banner.
			restore: { MainActor.assumeIsolated { _restore(snapshot, token: token, storage: storage, saveRestoration: saveRestoration) } },
            discard: {
                if let token {
                    do { try storage.recoverCertificateDeletion(token) }
                    catch { Logger.misc.error("Certificate erasure deferred; tracked private files retained for cleanup.") }
                }
            }
		))
        return true
	}

	/// Nil when no exact snapshot is available; deletion then has no Undo.
    /// A failed holding move throws instead, refusing deletion until rollback
    /// or durable recovery can put the surviving row's private bytes back.
    @MainActor
	private static func _prepareUndo(for cert: CertificatePair, storage: Storage) throws -> (Snapshot, StagedAppDeletion?)? {
		guard let uuid = cert.uuid, UUID(uuidString: uuid) != nil, let expiration = cert.expiration else { return nil }

		let password: String
		do {
			// Snapshot only: read-through migration would save unrelated view edits.
            // A locked Keychain refuses the undo offer, not a permission to guess.
            let stored = try SecureSecretStore.read("certificate.password.\(uuid)")
            password = stored.map { String(decoding: $0, as: UTF8.self) } ?? cert.password ?? ""
		} catch {
			Logger.misc.info("Certificate password unavailable; deleting without Undo.")
			return nil
		}

		var token: StagedAppDeletion?
		if let folder = storage.getUuidDirectory(for: cert), FileManager.default.fileExists(atPath: folder.path) {
			do {
                guard Storage.allowedCertificateDeletionOriginal(folder) else { throw CleanupRemovalPolicy.Rejection.unsafeTarget }
                let root = try Storage.prepareCertificateDeletionRoot()
                let staged = try StagedAppDeletion(root: root, originals: [(folder, cert.objectID.uriRepresentation())])
                guard CleanupRemovalPolicy.isSafeDirectory(staged.directory, beneath: root) else {
                    throw CleanupRemovalPolicy.Rejection.unsafeTarget
                }
                token = staged
                try staged.stage()
			} catch {
                if let token {
                    do { try token.recover(rowExists: { _ in true }, allowedOriginal: Storage.allowedCertificateDeletionOriginal) }
                    catch { Logger.misc.error("Certificate holding failed; durable rollback journal retained for recovery.") }
                }
                Logger.misc.error("Certificate files could not be set aside; deletion refused.")
                throw error
			}
		}

		let signed = (cert.signedApps as? Set<Signed>) ?? []
		return (
			Snapshot(
				uuid: uuid,
				nickname: cert.nickname,
				ppq: cert.ppQCheck,
				expiration: expiration,
				isDefault: cert.isDefault,
				revoked: cert.revoked,
				date: cert.date,
				password: password,
				signedAppURIs: signed.map { $0.objectID.uriRepresentation() }
			),
			token
		)
	}

	@MainActor
	private static func _restore(_ snapshot: Snapshot, token: StagedAppDeletion?, storage: Storage,
        saveRestoration: (NSManagedObjectContext) throws -> Void) -> Bool {
        // An independently imported identity must never be overwritten by an old
        // offer. An unreadable store is not evidence that the identity is absent.
        do { guard try !storage.containsCertificateIdentity(uuid: snapshot.uuid) else { return false } }
        catch { Toast.error(error.localizedDescription); return false }
		// Files first: a row without its .p12 is a certificate that cannot sign.
		if let token {
			do {
                try token.recover(rowExists: { _ in true }, allowedOriginal: Storage.allowedCertificateDeletionOriginal,
                    retainingManifest: true)
			} catch {
				Toast.error(error.localizedDescription)
				return false
			}
		}

		var failure: Error?
        storage.addCertificate(uuid: snapshot.uuid, password: snapshot.password, nickname: snapshot.nickname,
            ppq: snapshot.ppq, expiration: snapshot.expiration, isDefault: snapshot.isDefault,
            date: snapshot.date, revoked: snapshot.revoked, relinkingSignedAppURIs: snapshot.signedAppURIs,
            saveCertificate: saveRestoration) { failure = $0 }
        if let failure {
            // A failed isolated insert committed neither a row nor links. Keep
            // the private files under the original six-second erasure offer.
            if let token {
                do { try token.stage() }
                catch {
                    // The retained manifest still owns the restored original.
                    // Expiry/launch recovery checks for a replacement UUID owner
                    // before erasing either location; unreadable stores defer.
                    Logger.misc.error("Could not re-stage failed certificate restore; durable journal retained until expiry or recovery.")
                }
            }
            Toast.error(failure.localizedDescription)
            return false
        }

        if let token {
            do { try token.recover(rowExists: { _ in false }, allowedOriginal: Storage.allowedCertificateDeletionOriginal) }
            catch { Logger.misc.error("Restored certificate journal cleanup deferred; certificate files retained.") }
        }
		return true
	}
}
