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
import Combine
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
		// Non-optional in the model, so set them instead of relying on defaults.
		certificate.ppQCheck = false
		certificate.isDefault = false
		certificate.revoked = false
		certificate.date = Date()
		try storage.context.save()

		// No files were ever written for this row, so there is nothing to remove. The point is
		// that deletion does not depend on the directory existing or on the removal succeeding.
        let uuid = certificate.uuid
        XCTAssertTrue(storage.deleteCertificate(for: certificate))

		let request = CertificatePair.fetchRequest()
		let remaining = try storage.context.fetch(request)
		XCTAssertFalse(
			remaining.contains { $0.uuid == uuid },
			"the row must go even when the files cannot be"
		)
	}

	/// The failure path logs; it must not throw, and it must not skip the row deletion. This
	/// asserts the shape of the code rather than the log, because `Logger` output is not
	/// capturable from a unit test without a custom log handler.
	@MainActor
	func testTheFileRemovalFailureIsReportedNotSwallowed() throws {
		let source = try RepositorySourceFixture.read("VexSign/App/iOS/Infrastructure/Persistence/Database/Storage+Certificate.swift")
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

        // Persistence is the commit point. A failed save cannot erase a
        // surviving row's private files/password; post-commit cleanup is logged.
        let commit = try XCTUnwrap(body.range(of: "try saveDeletion(deletion)"))
        let secret = try XCTUnwrap(body.range(of: "try SecureSecretStore.delete"))
        let files = try XCTUnwrap(body.range(of: "try FileManager.default.removeItem(at: directory)"))
        XCTAssertLessThan(commit.lowerBound, secret.lowerBound)
        XCTAssertLessThan(commit.lowerBound, files.lowerBound)
        XCTAssertTrue(body.contains("deletion.rollback()"))
        XCTAssertTrue(body.contains("Certificate deletion could not be saved; credential and files retained."))
	}

	@MainActor
	func testTheStagedImportCleanupReportsAFailureToo() throws {
		// The same directory is written by `CertificateFileHandler.copy()` before the row
		// exists, so a failed import leaves a private key behind with no row to own it.
		let source = try RepositorySourceFixture.read("VexSign/App/iOS/Infrastructure/Identity/CertificateFileHandler.swift")
		let start = try XCTUnwrap(source.range(of: "func clean()"))
		let body = String(source[start.lowerBound...].prefix(900))

		XCTAssertTrue(body.contains("catch"), "cleanup must handle a failed removal")
		XCTAssertTrue(body.contains("Logger.misc.error"), "a failed cleanup must be recorded")
	}
    @MainActor
    private func certificate(in storage: Storage, uuid: String = UUID().uuidString) throws -> CertificatePair {
        let row = CertificatePair(context: storage.context)
        row.uuid = uuid; row.nickname = "Fixture"; row.expiration = Date().addingTimeInterval(3600)
        row.date = nil; row.ppQCheck = false; row.isDefault = false; row.revoked = false
        try storage.context.save()
        return row
    }

    @MainActor
    func testFailedSaveRetainsCredentialFilesAndUnrelatedPendingEdits() throws {
        let storage = _storage()
        let row = try certificate(in: storage)
        let uuid = try XCTUnwrap(row.uuid)
        let account = "certificate.password.\(uuid)"
        try row.setSigningPassword("fixture-password")
        let unrelated = Imported(context: storage.context)
        unrelated.uuid = UUID().uuidString; unrelated.name = "Before"
        try storage.context.save()
        unrelated.name = "Unsaved"
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: row))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.p12")
        try Data("synthetic fixture, not a key".utf8).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: directory) // try? ok: synthetic test teardown
            try? SecureSecretStore.delete(account) // try? ok: random test credential teardown
        }
        var attempted = false
        XCTAssertFalse(storage.deleteCertificate(for: row, saveDeletion: { context in
            attempted = true
            XCTAssertEqual(context.deletedObjects.count, 1)
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        XCTAssertTrue(attempted)
        XCTAssertFalse(row.isDeleted)
        XCTAssertEqual(try SecureSecretStore.read(account), Data("fixture-password".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(unrelated.name, "Unsaved")
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = storage.container.persistentStoreCoordinator
        XCTAssertEqual((try reader.existingObject(with: unrelated.objectID) as? Imported)?.name, "Before")
    }

    @MainActor
    func testFailedRemovalRestoresHeldFilesWithoutSavingUnrelatedEdits() throws {
        let storage = _storage()
        let row = try certificate(in: storage)
        row.password = "legacy fixture"
        let unrelated = Imported(context: storage.context)
        unrelated.uuid = UUID().uuidString; unrelated.name = "Before"
        try storage.context.save()
        unrelated.name = "Pending"
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: row))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.p12")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) } // try? ok: synthetic test teardown
        var announcements = 0
        let observation = NotificationCenter.default.publisher(for: UndoableRemoval.announced).sink { _ in announcements += 1 }
        defer { observation.cancel() }
        XCTAssertFalse(CertificateRemoval.delete(row, storage: storage, saveDeletion: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
        XCTAssertEqual(announcements, 0)
        XCTAssertEqual(row.password, "legacy fixture")
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = storage.container.persistentStoreCoordinator
        XCTAssertEqual((try reader.existingObject(with: unrelated.objectID) as? Imported)?.name, "Before")
        XCTAssertEqual(unrelated.name, "Pending")
    }

    @MainActor
    func testFailedImportRollsBackItsRowAndKeychainWrite() throws {
        let storage = _storage()
        let uuid = UUID().uuidString
        let account = "certificate.password.\(uuid)"
        defer { try? SecureSecretStore.delete(account) } // try? ok: random test credential teardown
        var attempted = false
        var failure: Error?
        storage.addCertificate(uuid: uuid, password: "fixture", expiration: Date(), saveCertificate: { _ in
            attempted = true; throw CocoaError(.fileWriteOutOfSpace)
        }) { failure = $0 }
        XCTAssertTrue(attempted)
        XCTAssertNotNil(failure)
        XCTAssertFalse(try storage.context.fetch(CertificatePair.fetchRequest()).contains { $0.uuid == uuid })
        XCTAssertNil(try SecureSecretStore.read(account))
    }

    @MainActor
    func testDuplicateAndInvalidUUIDsAreRefusedBeforeCredentialReplacement() throws {
        let storage = _storage()
        let row = try certificate(in: storage)
        let uuid = try XCTUnwrap(row.uuid)
        let account = "certificate.password.\(uuid)"
        try row.setSigningPassword("original fixture")
        try storage.context.save()
        defer { try? SecureSecretStore.delete(account) } // try? ok: random test credential teardown
        var failure: Error?
        storage.addCertificate(uuid: uuid, password: "must not overwrite", expiration: Date()) { failure = $0 }
        XCTAssertEqual(failure as? WorkspaceAccessError, .mismatchedRecord)
        XCTAssertEqual(try SecureSecretStore.read(account), Data("original fixture".utf8))
        failure = nil
        storage.addCertificate(uuid: uuid.lowercased(), password: "case variant must not overwrite", expiration: Date()) { failure = $0 }
        XCTAssertEqual(failure as? WorkspaceAccessError, .mismatchedRecord)
        XCTAssertEqual(try SecureSecretStore.read(account), Data("original fixture".utf8))
        failure = nil
        storage.addCertificate(uuid: "../not-an-identity", password: "must not write", expiration: Date()) { failure = $0 }
        XCTAssertEqual(failure as? WorkspaceAccessError, .invalidReference)
    }

    @MainActor
    func testFailedUndoInsertionRestagesFilesAndCanRetryWithoutSavingUnrelatedEdits() throws {
        let storage = _storage()
        let row = try certificate(in: storage)
        let uuid = try XCTUnwrap(row.uuid)
        row.password = "legacy fixture"
        let unrelated = Imported(context: storage.context)
        unrelated.uuid = UUID().uuidString; unrelated.name = "Before"
        try storage.context.save()
        unrelated.name = "Pending"
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: row))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: directory.appendingPathComponent("fixture.p12"))
        defer {
            try? FileManager.default.removeItem(at: directory) // try? ok: synthetic test teardown
            try? SecureSecretStore.delete("certificate.password.\(uuid)") // try? ok: random test credential teardown
        }
        var removal: UndoableRemoval?
        let observation = NotificationCenter.default.publisher(for: UndoableRemoval.announced).sink {
            removal = $0.userInfo?["removal"] as? UndoableRemoval
        }
        defer { observation.cancel() }
        var saves = 0
        XCTAssertTrue(CertificateRemoval.delete(row, storage: storage, saveRestoration: { context in
            saves += 1
            if saves == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            try context.save()
        }))
        let offer = try XCTUnwrap(removal)
        XCTAssertFalse(UndoableRemoval.undo(offer))
        XCTAssertFalse(try storage.containsCertificateIdentity(uuid: uuid))
        XCTAssertNil(try SecureSecretStore.read("certificate.password.\(uuid)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "failed insertion must re-stage its private files")
        XCTAssertEqual(unrelated.name, "Pending")
        XCTAssertTrue(UndoableRemoval.undo(offer))
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("fixture.p12")), Data([7, 8, 9]))
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = storage.container.persistentStoreCoordinator
        XCTAssertEqual((try reader.existingObject(with: unrelated.objectID) as? Imported)?.name, "Before")
        XCTAssertEqual(unrelated.name, "Pending")
    }

    @MainActor
    func testCertificateJournalProtectsReplacementUUIDOwnerNotOnlyOldObjectID() throws {
        let storage = _storage()
        let row = try certificate(in: storage)
        let uuid = try XCTUnwrap(row.uuid)
        let originalID = row.objectID
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: row))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([10, 11]).write(to: directory.appendingPathComponent("fixture.p12"))
        defer {
            try? FileManager.default.removeItem(at: directory) // try? ok: synthetic test teardown
            try? FileManager.default.removeItem(at: root) // try? ok: synthetic test teardown
        }
        let journal = try StagedAppDeletion(root: root, originals: [(directory, originalID.uriRepresentation())])
        try journal.stage()
        storage.context.delete(row)
        try storage.context.save()
        try journal.recover(rowExists: { _ in true }, allowedOriginal: Storage.allowedCertificateDeletionOriginal, retainingManifest: true)
        let replacement = try certificate(in: storage, uuid: uuid)
        XCTAssertNotEqual(replacement.objectID, originalID)
        // Even a pending view deletion cannot hide this committed owner.
        storage.context.delete(replacement)
        XCTAssertTrue(try storage.containsCertificateIdentity(uuid: uuid))
        try storage.recoverCertificateDeletion(journal)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("fixture.p12")), Data([10, 11]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.directory.path))
        storage.context.rollback()
    }

    @MainActor
    func testMissingPersistentStoreDefersCertificateJournalWithoutErasingOriginal() throws {
        let storage = _storage()
        let row = try certificate(in: storage)
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: row))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([12]).write(to: directory.appendingPathComponent("fixture.p12"))
        defer {
            try? FileManager.default.removeItem(at: directory) // try? ok: synthetic test teardown
            try? FileManager.default.removeItem(at: root) // try? ok: synthetic test teardown
        }
        let journal = try StagedAppDeletion(root: root, originals: [(directory, row.objectID.uriRepresentation())])
        let store = try XCTUnwrap(storage.container.persistentStoreCoordinator.persistentStores.first)
        try storage.container.persistentStoreCoordinator.remove(store)
        XCTAssertThrowsError(try storage.recoverCertificateDeletion(journal))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture.p12").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.directory.appendingPathComponent("manifest.json").path))
    }

    @MainActor
    func testUndoPreservesNilDateAndRestoresOnlyStillEligibleSignedLinks() throws {
        let storage = _storage()
        let row = try certificate(in: storage)
        row.password = "legacy fixture"
        row.ppQCheck = true; row.isDefault = true; row.revoked = true
        let uuid = try XCTUnwrap(row.uuid)
        let oldID = row.objectID
        let replacement = try certificate(in: storage)
        let eligible = Signed(context: storage.context)
        eligible.uuid = UUID().uuidString; eligible.certificate = row
        let relinked = Signed(context: storage.context)
        relinked.uuid = UUID().uuidString; relinked.certificate = row
        try storage.context.save()
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: row))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([4, 5, 6]).write(to: directory.appendingPathComponent("fixture.p12"))
        defer {
            try? FileManager.default.removeItem(at: directory) // try? ok: synthetic test teardown
            try? SecureSecretStore.delete("certificate.password.\(uuid)") // try? ok: random test credential teardown
        }
        var removal: UndoableRemoval?
        let observation = NotificationCenter.default.publisher(for: UndoableRemoval.announced).sink {
            removal = $0.userInfo?["removal"] as? UndoableRemoval
        }
        defer { observation.cancel() }
        XCTAssertTrue(CertificateRemoval.delete(row, storage: storage))
        relinked.certificate = replacement
        try storage.context.save()
        let offer = try XCTUnwrap(removal)
        XCTAssertTrue(UndoableRemoval.undo(offer))
        XCTAssertFalse(UndoableRemoval.undo(offer))
        let restored = try XCTUnwrap(try storage.context.fetch(CertificatePair.fetchRequest()).first { $0.uuid == uuid })
        XCTAssertNotEqual(restored.objectID, oldID)
        XCTAssertNil(restored.date)
        XCTAssertTrue(restored.ppQCheck && restored.isDefault && restored.revoked)
        XCTAssertEqual(eligible.certificate?.objectID, restored.objectID)
        XCTAssertEqual(relinked.certificate?.objectID, replacement.objectID)
        XCTAssertEqual(try SecureSecretStore.read("certificate.password.\(uuid)"), Data("legacy fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("fixture.p12")), Data([4, 5, 6]))
    }

}
