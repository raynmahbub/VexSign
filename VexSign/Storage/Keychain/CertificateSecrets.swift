//
//  CertificateSecrets.swift
//  VexSign
//
//  The Core Data bridge for certificate passwords: reads the Keychain, migrates a
//  legacy plaintext column into it, and clears that column without saving the
//  caller's whole context.
//
//  Storage owns persistence, so this extension lives here rather than next to the
//  policy it uses. `Security/Credentials/CertificatePasswordMigration` decides the
//  ordering (secure write first, plaintext cleared only afterwards); this file only
//  supplies the managed-object side of that order.
//

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
        let account = SecureSecretStore.certificatePasswordAccount(uuid)
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
        try SecureSecretStore.write(Data(value.utf8), account: SecureSecretStore.certificatePasswordAccount(uuid))
        password = nil
    }
}
