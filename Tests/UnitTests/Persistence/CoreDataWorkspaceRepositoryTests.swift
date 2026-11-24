import CoreData
import XCTest
@testable import VexSign

@MainActor
final class CoreDataWorkspaceRepositoryTests: XCTestCase {
    private func rows(in storage: Storage, uuid: String = UUID().uuidString) throws -> (Signed, Imported) {
        let signed = Signed(context: storage.context)
        signed.uuid = uuid
        signed.name = "Signed fixture"
        signed.identifier = "test.fixture.signed"
        signed.sortIndex = 3
        let imported = Imported(context: storage.context)
        imported.uuid = uuid
        imported.name = "Imported fixture"
        imported.identifier = "test.fixture.imported"
        imported.sortIndex = 4
        try storage.context.save()
        return (signed, imported)
    }

    func testOwnPermanentTypedRowsKeepTheirStoreIdentityAndMetadata() throws {
        let storage = Storage(inMemory: true)
        let repository = CoreDataWorkspaceRepository(storage: storage)
        let (signed, imported) = try rows(in: storage)
        let certificate = CertificatePair(context: storage.context)
        certificate.uuid = UUID().uuidString
        certificate.ppQCheck = false
        certificate.isDefault = false
        certificate.revoked = false
        signed.certificate = certificate
        signed.source = URL(string: "https://example.com/fixture.json")
        try storage.context.save()

        // Keep these statically typed: overload resolution used to bypass the
        // ownership gate for Signed and Imported even when existential calls did not.
        let signedRecord = try repository.appRecord(signed)
        let importedRecord = try repository.appRecord(imported)
        XCTAssertEqual(signedRecord.id, signed.objectID.uriRepresentation().absoluteString)
        XCTAssertEqual(importedRecord.id, imported.objectID.uriRepresentation().absoluteString)
        XCTAssertEqual(signedRecord.uuid, importedRecord.uuid)
        XCTAssertTrue(signedRecord.isSigned)
        XCTAssertFalse(importedRecord.isSigned)
        XCTAssertEqual(signedRecord.name, "Signed fixture")
        XCTAssertEqual(importedRecord.name, "Imported fixture")
        XCTAssertEqual(signedRecord.sortIndex, 3)
        XCTAssertEqual(importedRecord.sortIndex, 4)
        XCTAssertEqual(signedRecord.source, signed.source)
        XCTAssertEqual(signedRecord.certificateID, certificate.objectID.uriRepresentation().absoluteString)
        XCTAssertNil(importedRecord.certificateID)
        XCTAssertEqual(signedRecord.artifactURL, storage.getUuidDirectory(for: signed))
        XCTAssertEqual(importedRecord.bundleURL, storage.getAppDirectory(for: imported))
        let snapshot = try repository.readWorkspace()
        XCTAssertEqual(snapshot.signedApps, [signedRecord])
        XCTAssertEqual(snapshot.importedApps, [importedRecord])
    }

    func testTypedForeignStoreRowsAreRefusedEvenWhenUUIDsMatch() throws {
        let storage = Storage(inMemory: true)
        let foreign = Storage(inMemory: true)
        let repository = CoreDataWorkspaceRepository(storage: storage)
        let uuid = UUID().uuidString
        let (ownedSigned, ownedImported) = try rows(in: storage, uuid: uuid)
        let (foreignSigned, foreignImported) = try rows(in: foreign, uuid: uuid)
        XCTAssertThrowsError(try repository.appRecord(foreignSigned)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
        XCTAssertThrowsError(try repository.appRecord(foreignImported)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
        XCTAssertEqual(try repository.appRecord(ownedSigned).id, ownedSigned.recordID)
        XCTAssertEqual(try repository.appRecord(ownedImported).id, ownedImported.recordID)
    }

    func testTypedRowsFromAnotherContextOfTheSameStoreAreRefused() throws {
        let storage = Storage(inMemory: true)
        let repository = CoreDataWorkspaceRepository(storage: storage)
        let (signed, imported) = try rows(in: storage)
        let reader = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        reader.persistentStoreCoordinator = storage.container.persistentStoreCoordinator
        let otherSigned = try XCTUnwrap(try reader.existingObject(with: signed.objectID) as? Signed)
        let otherImported = try XCTUnwrap(try reader.existingObject(with: imported.objectID) as? Imported)
        XCTAssertThrowsError(try repository.appRecord(otherSigned)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
        XCTAssertThrowsError(try repository.appRecord(otherImported)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
    }

    func testTypedTemporaryRowsAreRefusedBeforeProjection() {
        let storage = Storage(inMemory: true)
        let repository = CoreDataWorkspaceRepository(storage: storage)
        let signed = Signed(context: storage.context)
        let imported = Imported(context: storage.context)
        XCTAssertTrue(signed.objectID.isTemporaryID)
        XCTAssertTrue(imported.objectID.isTemporaryID)
        XCTAssertThrowsError(try repository.appRecord(signed)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
        XCTAssertThrowsError(try repository.appRecord(imported)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
    }

    func testTypedPendingDeletionsAreRefused() throws {
        let storage = Storage(inMemory: true)
        let repository = CoreDataWorkspaceRepository(storage: storage)
        let (signed, imported) = try rows(in: storage)
        storage.context.delete(signed)
        storage.context.delete(imported)
        XCTAssertTrue(signed.isDeleted)
        XCTAssertTrue(imported.isDeleted)
        XCTAssertThrowsError(try repository.appRecord(signed)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
        XCTAssertThrowsError(try repository.appRecord(imported)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
    }

    func testTypedCommittedDeletionsCannotBeReprojected() throws {
        let storage = Storage(inMemory: true)
        let repository = CoreDataWorkspaceRepository(storage: storage)
        let (signed, imported) = try rows(in: storage)
        storage.context.delete(signed)
        storage.context.delete(imported)
        try storage.context.save()
        XCTAssertThrowsError(try repository.appRecord(signed)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
        XCTAssertThrowsError(try repository.appRecord(imported)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
    }

    func testDetachedRowsAndImmutableValuesCannotMasqueradeAsOwnedRows() throws {
        let storage = Storage(inMemory: true)
        let repository = CoreDataWorkspaceRepository(storage: storage)
        let (signed, imported) = try rows(in: storage)
        let value = try repository.appRecord(signed)
        storage.context.reset()
        XCTAssertThrowsError(try repository.appRecord(signed)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
        XCTAssertThrowsError(try repository.appRecord(imported)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
        XCTAssertThrowsError(try repository.appRecord(value)) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
    }

    func testWorkspaceReadCannotLeakATemporaryIdentityAndRecoversAfterSave() throws {
        let storage = Storage(inMemory: true)
        let repository = CoreDataWorkspaceRepository(storage: storage)
        let imported = Imported(context: storage.context)
        imported.uuid = UUID().uuidString
        imported.name = "Pending fixture"
        XCTAssertThrowsError(try repository.readWorkspace()) {
            XCTAssertEqual($0 as? WorkspaceAccessError, .mismatchedRecord)
        }
        try storage.context.save()
        let snapshot = try repository.readWorkspace()
        XCTAssertEqual(snapshot.importedApps.map(\.id), [imported.objectID.uriRepresentation().absoluteString])
        XCTAssertEqual(snapshot.importedApps.first?.name, "Pending fixture")
    }
}
