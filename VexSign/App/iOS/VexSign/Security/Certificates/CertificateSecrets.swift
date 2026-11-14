import Foundation
import CoreData
import OSLog

extension CertificatePair {
    /// Read-through migration leaves legacy storage untouched if Keychain is locked.
    /// Signing fails closed instead of interpreting a locked Keychain as a saved password.
    var signingPassword: String? {
        do { return try requireSigningPassword() }
        catch {
            Logger.misc.error("Certificate password is unavailable; inspect credential migration warnings.")
            return nil
        }
    }

    /// The injected operations are per call, never global Keychain overrides.
    /// Migration persists only this row's old password field, not unrelated edits
    /// pending in the caller's context. No password or underlying error is logged.
    func requireSigningPassword(
        readSecret: (String) throws -> Data? = { try SecureSecretStore.read($0) },
        writeSecret: (Data, String) throws -> Void = { try SecureSecretStore.write($0, account: $1) },
        saveMigration: (NSManagedObjectContext) throws -> Void = { try $0.save() }
    ) throws -> String {
        guard let uuid, UUID(uuidString: uuid) != nil else { throw RepositoryError.invalid("Certificate has no valid identifier.") }
        guard managedObjectContext != nil, !isDeleted else { throw RepositoryError.invalid("Certificate is no longer available in its owning store.") }
        let account = "certificate.password.\(uuid)"
        do {
            let value = try CertificatePasswordMigration.resolve(legacy: password,
                read: { try readSecret(account) },
                write: { try writeSecret($0, account) },
                clearLegacy: {
                    if let original = password {
                        try clearLegacySigningPassword(original, uuid: uuid, save: saveMigration)
                    }
                })
            CredentialMigrationDiagnostics.report(source: .certificatePassword, id: uuid, issue: nil)
            return value
        } catch {
            CredentialMigrationDiagnostics.report(source: .certificatePassword, id: uuid,
                                                   issue: CredentialMigrationIssue.classify(error))
            throw error
        }
    }

    private func clearLegacySigningPassword(_ original: String, uuid: String,
                                            save: (NSManagedObjectContext) throws -> Void) throws {
        guard let context = managedObjectContext, !isDeleted else {
            throw RepositoryError.invalid("Certificate password migration needs its owning store.")
        }
        if objectID.isTemporaryID {
            // The plaintext was never committed. A secure write already succeeded;
            // leave insertion and every other pending edit to their existing owner.
            password = nil
            return
        }
        guard let coordinator = context.persistentStoreCoordinator, !coordinator.persistentStores.isEmpty else {
            throw RepositoryError.invalid("Certificate password migration needs its owning store.")
        }
        let id = objectID
        let transaction = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        transaction.persistentStoreCoordinator = coordinator
        transaction.mergePolicy = NSErrorMergePolicy
        try transaction.performAndWait {
            guard let row = try transaction.existingObject(with: id) as? CertificatePair,
                  row.uuid == uuid, row.password == nil || row.password == original else {
                throw RepositoryError.invalid("Certificate password changed during migration. Review the identity again.")
            }
            row.password = nil
            if transaction.hasChanges { try save(transaction) }
        }
        // Do not save/refresh the caller's whole context. Its unrelated pending
        // changes remain pending; the existing automatic merge observes the save.
        password = nil
    }

    func setSigningPassword(_ value: String) throws {
        guard let uuid, UUID(uuidString: uuid) != nil else { throw RepositoryError.invalid("Certificate has no valid identifier.") }
        guard managedObjectContext != nil, !isDeleted else { throw RepositoryError.invalid("Certificate is no longer available in its owning store.") }
        try SecureSecretStore.write(Data(value.utf8), account: "certificate.password.\(uuid)")
        password = nil
    }
}

/// Original plaintext may be cleared only after a successful secure read/write.
/// Dependencies are injectable so failure ordering can be tested without secrets.
enum CertificatePasswordMigration {
    static func resolve(legacy: String?, read: () throws -> Data?,
                        write: (Data) throws -> Void, clearLegacy: () throws -> Void) throws -> String {
        if let stored = try read() {
            guard let value = String(data: stored, encoding: .utf8) else {
                throw RepositoryError.invalid("The saved certificate password is unreadable. Re-enter it in Certificates.")
            }
            try clearLegacy()
            return value
        }
        let value = legacy ?? ""
        try write(Data(value.utf8))
        try clearLegacy()
        return value
    }
}
