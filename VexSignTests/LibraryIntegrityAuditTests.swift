//
//  LibraryIntegrityAuditTests.swift
//  VexSignTests
//
//  The audit reports invariants the store does not enforce. These tests pin the checks
//  themselves, the fact that an audit never mutates its input, and the one property that
//  makes it safe to attach to a support bundle: the exported summary carries counts, not
//  names, identifiers or uuids.
//

import XCTest
@testable import VexSign

final class LibraryIntegrityAuditTests: XCTestCase {
    private func row(
        uuid: String? = "uuid-1",
        identifier: String? = "com.example.app",
        isSigned: Bool = false,
        certificateUUID: String? = nil,
        directory: Bool = true
    ) -> LibraryIntegrityAudit.Row {
        LibraryIntegrityAudit.Row(
            uuid: uuid,
            identifier: identifier,
            isSigned: isSigned,
            certificateUUID: certificateUUID,
            hasArtifactDirectory: directory
        )
    }

    // MARK: - Healthy library

    func testAHealthyLibraryHasNoFindings() {
        let report = LibraryIntegrityAudit.audit(
            rows: [
                row(uuid: "a", directory: true),
                row(uuid: "b", isSigned: true, certificateUUID: "CERT-1", directory: true)
            ],
            certificateUUIDs: ["cert-1"]
        )
        XCTAssertTrue(report.isHealthy)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.rowCount, 2)
        XCTAssertEqual(report.unusableRowCount, 0)
    }

    // MARK: - Identity

    func testARowWithoutAUUIDIsReportedAndSkippedByLaterChecks() {
        // Without a uuid the row cannot own a directory, so reporting artifactMissing as well
        // would be noise from the same cause.
        let report = LibraryIntegrityAudit.audit(rows: [row(uuid: nil, directory: false)], certificateUUIDs: [])
        XCTAssertEqual(report.findings.map(\.code), [.missingUUID])
    }

    func testAnEmptyOrWhitespaceUUIDCountsAsMissing() {
        XCTAssertEqual(LibraryIntegrityAudit.audit(rows: [row(uuid: "  ")], certificateUUIDs: []).findings.map(\.code), [.missingUUID])
        XCTAssertEqual(LibraryIntegrityAudit.audit(rows: [row(uuid: "")], certificateUUIDs: []).findings.map(\.code), [.missingUUID])
    }

    func testTwoRowsSharingAUUIDAreBothReported() {
        let report = LibraryIntegrityAudit.audit(
            rows: [row(uuid: "dup"), row(uuid: "dup")],
            certificateUUIDs: []
        )
        XCTAssertEqual(report.findings.filter { $0.code == .duplicateUUID }.map(\.rowIndex).sorted(), [0, 1])
    }

    func testDuplicateDetectionIgnoresCase() {
        // The store lowercases uuids; two rows differing only by case would resolve to the
        // same directory on a case-insensitive volume.
        let report = LibraryIntegrityAudit.audit(rows: [row(uuid: "ABC"), row(uuid: "abc")], certificateUUIDs: [])
        XCTAssertEqual(report.count(of: .duplicateUUID), 2)
    }

    // MARK: - Artifacts and identifiers

    func testAMissingArtifactDirectoryIsSerious() {
        let report = LibraryIntegrityAudit.audit(rows: [row(uuid: "a", directory: false)], certificateUUIDs: [])
        XCTAssertEqual(report.findings.map(\.code), [.artifactMissing])
        XCTAssertEqual(report.findings.first?.severity, .serious)
        XCTAssertEqual(report.unusableRowCount, 1)
    }

    func testAMissingIdentifierIsReported() {
        XCTAssertEqual(
            LibraryIntegrityAudit.audit(rows: [row(uuid: "a", identifier: nil)], certificateUUIDs: []).findings.map(\.code),
            [.identifierMissing]
        )
        XCTAssertEqual(
            LibraryIntegrityAudit.audit(rows: [row(uuid: "a", identifier: "   ")], certificateUUIDs: []).findings.map(\.code),
            [.identifierMissing]
        )
    }

    // MARK: - Identity references

    func testASignedRowWithoutAnIdentityIsReported() {
        let report = LibraryIntegrityAudit.audit(rows: [row(uuid: "a", isSigned: true)], certificateUUIDs: [])
        XCTAssertEqual(report.findings.map(\.code), [.signedWithoutCertificate])
        XCTAssertEqual(report.findings.first?.severity, .degraded)
    }

    func testASignedRowForAnIdentityThatIsGoneIsReported() {
        // The install still works; the provenance does not.
        let report = LibraryIntegrityAudit.audit(
            rows: [row(uuid: "a", isSigned: true, certificateUUID: "deleted-cert")],
            certificateUUIDs: ["another-cert"]
        )
        XCTAssertEqual(report.findings.map(\.code), [.orphanedCertificate])
        XCTAssertEqual(report.unusableRowCount, 0)
    }

    func testAnUnsignedRowIsNotCheckedForAnIdentity() {
        // An imported app legitimately has no certificate; reporting one would be noise.
        XCTAssertTrue(
            LibraryIntegrityAudit.audit(rows: [row(uuid: "a", isSigned: false)], certificateUUIDs: []).isHealthy
        )
    }

    // MARK: - Ordering and stability

    func testFindingsAreSortedByRowThenCode() {
        let report = LibraryIntegrityAudit.audit(
            rows: [
                row(uuid: "a", identifier: nil, directory: false),
                row(uuid: "b", identifier: nil, directory: false)
            ],
            certificateUUIDs: []
        )
        XCTAssertEqual(report.findings.map(\.rowIndex), [0, 0, 1, 1])
        XCTAssertEqual(
            report.findings.map(\.code.rawValue),
            report.findings.map(\.code.rawValue).sorted()
        )
    }

    func testAnAuditDoesNotChangeItsInput() {
        let rows = [row(uuid: "a", directory: false)]
        let copy = rows
        _ = LibraryIntegrityAudit.audit(rows: rows, certificateUUIDs: [])
        XCTAssertEqual(rows, copy)
    }

    // MARK: - Export

    func testTheExportCarriesCountsAndNoIdentifiers() throws {
        let report = LibraryIntegrityAudit.audit(
            rows: [row(uuid: "SECRET-UUID", identifier: "com.secret.app", directory: false)],
            certificateUUIDs: []
        )
        let json = report.jsonObject
        XCTAssertEqual(json["rows"] as? Int, 1)
        XCTAssertEqual(json["unusableRows"] as? Int, 1)
        let counts = try XCTUnwrap(json["findings"] as? [String: Int])
        XCTAssertEqual(counts["artifactMissing"], 1)
        XCTAssertEqual(counts["duplicateUUID"], 0)
        let summary = try XCTUnwrap(json["summary"] as? String)
        XCTAssertFalse(summary.contains("SECRET-UUID"))
        XCTAssertFalse(summary.contains("com.secret.app"))
    }

    func testAHealthyExportSaysSoInWords() {
        let report = LibraryIntegrityAudit.audit(rows: [row(uuid: "a")], certificateUUIDs: [])
        XCTAssertEqual(
            report.jsonObject["summary"] as? String,
            "every row has a uuid, an identifier, an artifact directory and, when signed, an installed identity"
        )
    }
}
