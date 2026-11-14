import Foundation
@testable import VexSign

/// Values only. These are not real store identities, signing evidence or device receipts.
enum FeatureBoundaryFixtures {
    static func app(uuid: String? = UUID().uuidString, signed: Bool = false, recordID: String? = nil) -> LibraryAppRecord {
        LibraryAppRecord(id: recordID ?? "x-coredata://fixture/\(signed ? "Signed" : "Imported")/\(uuid ?? "missing")",
            uuid: uuid, isSigned: signed, name: "Fixture", version: "1.0", identifier: "com.example.fixture",
            originalIdentifier: "com.example.fixture", date: nil, icon: nil, appDescription: nil,
            sortIndex: 0, source: nil, certificateID: nil, bundleURL: nil, artifactURL: nil)
    }

    static func signing(id: String = "fixture-run", app: LibraryAppRecord = FeatureBoundaryFixtures.app(), options: Options = .defaultOptions) throws -> LibrarySigningRequest {
        LibrarySigningRequest(id: id, app: try LibraryAppReference(app: app), options: options,
            certificateID: nil, overridesBlockingPreflightIssues: false, notices: [])
    }

    static func task(kind: UnifiedTaskKind = .install, unknown: Bool = true) -> TaskRecord {
        TaskRecord(id: UUID().uuidString, kind: kind, title: "Fixture", subtitle: nil, phase: .unconfirmed,
            progress: 0, failureStage: nil, errorText: nil, createdAt: Date(), updatedAt: Date(),
            subjectID: nil, artifactID: nil, signingTrace: nil, displayPhaseTitle: "Unconfirmed",
            queryText: "fixture", receipt: "synthetic receipt", outcome: "unknown", outcomeUnknown: unknown, canRetry: true)
    }

    static func backup() -> BackupArchiveSnapshot {
        BackupArchiveSnapshot(id: UUID(), createdAt: Date(), appVersion: "fixture", schemaVersion: 1,
            contents: [.settings], counts: [.settings: 1],
            integrity: BackupIntegrity(packSHA256: "fixture-only", certificateEntries: 0, certificateDirectories: 0))
    }
}
