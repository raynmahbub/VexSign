//
//  ExpiryReminderSource.swift
//  VexSign
//
//  Reads the dates VexSign already stores for imported signing identities and
//  hands the scheduler immutable metadata. It never parses a private key or
//  reads a password to decide when a reminder should fire.
//

import Foundation
import CoreData

enum ExpiryReminderSource {
    /// The storage row carries the provisioning-profile expiry. The leaf
    /// certificate's own date is added by `CertificateInspector` when an
    /// inspected report is available, because that requires key material.
    @MainActor
    static func subjects(storage: Storage = .shared) -> [ExpiryReminderSubject] {
        let rows: [CertificatePair]
        do { rows = try storage.context.fetch(CertificatePair.fetchRequest()) }
        catch { return [] }
        return rows.compactMap { row in
            guard !row.isDeleted, let id = row.uuid, !id.isEmpty, let expiry = row.expiration else { return nil }
            return ExpiryReminderSubject(
                referenceID: id,
                kind: .profile,
                displayName: row.nickname ?? "Certificate",
                expiry: expiry
            )
        }
    }
}
