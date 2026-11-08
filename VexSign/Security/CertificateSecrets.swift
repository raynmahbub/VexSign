import Foundation
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

    func requireSigningPassword() throws -> String {
        guard let uuid else { throw RepositoryError.invalid("Certificate has no identifier.") }
        let account = "certificate.password.\(uuid)"
        do {
            let value = try CertificatePasswordMigration.resolve(legacy: password,
                read: { try SecureSecretStore.read(account) },
                write: { try SecureSecretStore.write($0, account: account) },
                clearLegacy: {
                    if password != nil {
                        let original = password
                        password = nil
                        do { try managedObjectContext?.save() }
                        catch {
                            password = original
                            throw error
                        }
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

    func setSigningPassword(_ value: String) throws {
        guard let uuid else { throw RepositoryError.invalid("Certificate has no identifier.") }
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
            try clearLegacy()
            return String(decoding: stored, as: UTF8.self)
        }
        let value = legacy ?? ""
        try write(Data(value.utf8))
        try clearLegacy()
        return value
    }
}
