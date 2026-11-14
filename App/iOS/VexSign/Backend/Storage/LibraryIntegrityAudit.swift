//
//  LibraryIntegrityAudit.swift
//  VexSign
//
//  The invariants the library store has never declared, checked.
//
//  `Storage` stores a row and a directory per application, and the two are linked only by
//  a `uuid` string. Nothing in the model enforces that the uuid is present, that two rows
//  do not share one, or that the directory still exists. Core Data will happily keep a
//  `Signed` row whose `certificate` was deleted, and the store has no unique constraint on
//  `uuid`, so a duplicate is possible even though no current caller creates one.
//
//  None of that is visible until a user hits it — an app tile that opens an empty screen, a
//  "sign" that fails on a missing bundle, a row whose identity nobody can name. This type
//  reports those states without changing them: it is an audit, not a repair. Nothing here
//  deletes, moves or rewrites a record, which is why it can run from a diagnostics export.
//
//  The export carries counts only. Row names, bundle identifiers and uuids stay on the
//  device: a support bundle should not list what the user has installed.
//

import Foundation

// MARK: - Audit

enum LibraryIntegrityAudit {
    /// One row, reduced to what the checks need.
    struct Row: Equatable {
        var uuid: String?
        var identifier: String?
        var isSigned: Bool
        /// The identity this row claims, when it is a signed copy.
        var certificateUUID: String?
        /// Whether the artifact directory for this row exists on disk.
        var hasArtifactDirectory: Bool

        init(
            uuid: String?,
            identifier: String?,
            isSigned: Bool,
            certificateUUID: String? = nil,
            hasArtifactDirectory: Bool
        ) {
            self.uuid = uuid
            self.identifier = identifier
            self.isSigned = isSigned
            self.certificateUUID = certificateUUID
            self.hasArtifactDirectory = hasArtifactDirectory
        }
    }

    /// A broken invariant. Codes are stable because they appear in exported diagnostics.
    enum Code: String, CaseIterable, Equatable {
        /// Two rows share a uuid, so a directory lookup is ambiguous.
        case duplicateUUID
        /// A row with no uuid cannot own a directory or be resolved at all.
        case missingUUID
        /// The row exists but its artifact directory does not: the app cannot be opened,
        /// signed or installed.
        case artifactMissing
        /// No bundle identifier: the row cannot be matched, updated or signed.
        case identifierMissing
        /// A signed row that names no identity.
        case signedWithoutCertificate
        /// A signed row whose identity is no longer in the store.
        case orphanedCertificate

        /// How much the finding actually breaks.
        ///
        /// `serious` means the row cannot be used for anything; `degraded` means it is usable
        /// but its provenance or one of its relationships is gone.
        var severity: Severity {
            switch self {
            case .duplicateUUID, .missingUUID, .artifactMissing, .identifierMissing:
                return .serious
            case .signedWithoutCertificate, .orphanedCertificate:
                return .degraded
            }
        }
    }

    enum Severity: String, Equatable {
        case serious
        case degraded
    }

    /// One finding, with the row it belongs to — which is why this never leaves the device.
    struct Finding: Equatable {
        let code: Code
        /// Index of the row in the audited snapshot. Kept instead of the uuid so a finding
        /// can be mapped back without printing an identifier into a log.
        let rowIndex: Int

        var severity: Severity { code.severity }
    }

    struct Report: Equatable {
        let rowCount: Int
        let findings: [Finding]

        var isEmpty: Bool { findings.isEmpty }
        var isHealthy: Bool { findings.isEmpty }

        func count(of code: Code) -> Int {
            findings.reduce(into: 0) { total, finding in
                if finding.code == code { total += 1 }
            }
        }

        /// The rows that cannot be used at all.
        var unusableRowCount: Int {
            Set(findings.filter { $0.severity == .serious }.map(\.rowIndex)).count
        }

        /// Counts only. No names, identifiers or uuids.
        var jsonObject: [String: Any] {
            var counts: [String: Any] = [:]
            for code in Code.allCases {
                counts[code.rawValue] = count(of: code)
            }
            return [
                "rows": rowCount,
                "unusableRows": unusableRowCount,
                "findings": counts,
                // One sentence, so a support bundle reader does not have to interpret counts.
                "summary": isHealthy
                    ? "every row has a uuid, an identifier, an artifact directory and, when signed, an installed identity"
                    : "\(findings.count) finding(s) across \(unusableRowCount) unusable row(s)"
            ]
        }
    }

    // MARK: Checks

    /// Audits one snapshot of the library.
    ///
    /// - Parameters:
    ///   - rows: every row, in the order the caller wants indices to refer to.
    ///   - certificateUUIDs: identities present in the store, lowercased.
    static func audit(rows: [Row], certificateUUIDs: Set<String>) -> Report {
        var findings: [Finding] = []
        var seen: [String: Int] = [:]

        for (index, row) in rows.enumerated() {
            guard let uuid = row.uuid?.trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty else {
                findings.append(Finding(code: .missingUUID, rowIndex: index))
                continue
            }

            // Case-insensitive: the store and the Keychain accounts both lowercase uuids, and
            // two rows differing only by case would resolve to the same directory.
            let key = uuid.lowercased()
            if seen[key] != nil {
                // Both rows are reported: either of them may be the stale copy.
                findings.append(Finding(code: .duplicateUUID, rowIndex: index))
                if let first = seen[key] {
                    findings.append(Finding(code: .duplicateUUID, rowIndex: first))
                }
            } else {
                seen[key] = index
            }

            if !row.hasArtifactDirectory {
                findings.append(Finding(code: .artifactMissing, rowIndex: index))
            }
            if (row.identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                findings.append(Finding(code: .identifierMissing, rowIndex: index))
            }

            guard row.isSigned else { continue }
            guard let certificate = row.certificateUUID?.trimmingCharacters(in: .whitespacesAndNewlines), !certificate.isEmpty else {
                findings.append(Finding(code: .signedWithoutCertificate, rowIndex: index))
                continue
            }
            if !certificateUUIDs.contains(certificate.lowercased()) {
                findings.append(Finding(code: .orphanedCertificate, rowIndex: index))
            }
        }

        // A row can trip several checks; report them in a stable order so two audits of the
        // same library compare equal.
        findings.sort { $0.rowIndex == $1.rowIndex ? $0.code.rawValue < $1.code.rawValue : $0.rowIndex < $1.rowIndex }
        return Report(rowCount: rows.count, findings: findings)
    }
}
