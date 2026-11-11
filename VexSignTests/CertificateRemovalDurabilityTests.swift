//
//  CertificateRemovalDurabilityTests.swift
//  VexSignTests
//
//  What happens when deleting a certificate cannot delete its files.
//
//  A certificate's directory holds the imported `.p12` — its private key — and the profile.
//  Removing the row is what tells the user the credential is gone from VexSign, so a file
//  removal that fails silently leaves usable key material on disk behind a screen that says
//  the certificate was deleted. These tests pin the two behaviours that make that safe:
//
//    1. the row is still deleted (a certificate that cannot be removed is worse), and
//    2. the failing removal is recorded rather than swallowed.
//
//  The orphan semantics that make (1) recoverable — a folder with no row is a leftover, and
//  an unreadable certificate list protects every folder — are already pinned by
//  `StorageLibrarySnapshotTests` and are not duplicated here.
//

import CoreData
import XCTest
@testable import VexSign

final class CertificateRemovalDurabilityTests: XCTestCase {
	private nonisolated(unsafe) static var storage: Storage?

	override func tearDown() {
		Self.storage = nil
		super.tearDown()
	}

	@MainActor
	private func _storage() -> Storage {
		if let storage = Self.storage { return storage }
		let storage = Storage(inMemory: true)
		Self.storage = storage
		return storage
	}

	// MARK: - Deletion still removes the row

	@MainActor
	func testDeletingACertificateRemovesItsRowEvenWhenTheFilesCannotBeRemoved() throws {
		let storage = _storage()
		let certificate = CertificatePair(context: storage.context)
		certificate.uuid = UUID().uuidString
		certificate.nickname = "Detached"
		certificate.expiration = Date().addingTimeInterval(86_400)
		try storage.context.save()

		// No files were ever written for this row, so there is nothing to remove. The point is
		// that deletion does not depend on the directory existing or on the removal succeeding.
		storage.deleteCertificate(for: certificate)

		let request = CertificatePair.fetchRequest()
		let remaining = try storage.context.fetch(request)
		XCTAssertFalse(
			remaining.contains { $0.uuid == certificate.uuid },
			"the row must go even when the files cannot be"
		)
	}

	/// The failure path logs; it must not throw, and it must not skip the row deletion. This
	/// asserts the shape of the code rather than the log, because `Logger` output is not
	/// capturable from a unit test without a custom log handler.
	@MainActor
	func testTheFileRemovalFailureIsReportedNotSwallowed() throws {
		let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("VexSign/Backend/Storage/Storage+Certificate.swift"))
		let start = try XCTUnwrap(source.range(of: "func deleteCertificate(for cert: CertificatePair)"))
		let body = String(source[start.lowerBound...])

		XCTAssertTrue(
			body.contains("catch"),
			"removing a certificate's files must have a failure path"
		)
		XCTAssertTrue(
			body.contains("Logger.misc.error"),
			"a failed removal of the private key must be recorded, not swallowed"
		)

		// And the row deletion must still happen after the failure branch.
		let catchRange = try XCTUnwrap(body.range(of: "Logger.misc.error"))
		let deleteRange = try XCTUnwrap(body.range(of: "context.delete(cert)"))
		XCTAssertLessThan(catchRange.lowerBound, deleteRange.lowerBound)
	}

	@MainActor
	func testTheStagedImportCleanupReportsAFailureToo() throws {
		// The same directory is written by `CertificateFileHandler.copy()` before the row
		// exists, so a failed import leaves a private key behind with no row to own it.
		let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("VexSign/Utilities/Handlers/CertificateFileHandler.swift"))
		let start = try XCTUnwrap(source.range(of: "func clean()"))
		let body = String(source[start.lowerBound...].prefix(900))

		XCTAssertTrue(body.contains("catch"), "cleanup must handle a failed removal")
		XCTAssertTrue(body.contains("Logger.misc.error"), "a failed cleanup must be recorded")
	}
}
