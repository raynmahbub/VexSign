//
//  CertificatePasswordMigration.swift
//  VexSign
//
//  The rule for moving a certificate password out of the legacy plaintext column
//  and into the Keychain. Security owns the ordering; the Core Data bridge that
//  applies it to a stored row lives in `VexSign/Storage/Keychain/CertificateSecrets.swift`,
//  which is the layer allowed to touch a managed object context.
//
//  Why the order matters: clearing the legacy column before the Keychain write
//  succeeds destroys the only copy of a password that can sign installs. Why the
//  decode matters: `String(decoding:as:)` replaces invalid UTF-8 with U+FFFD, so a
//  password would silently become a different password instead of failing.
//

import Foundation

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
