import CoreData
import XCTest
@testable import VexSign

@MainActor
final class SigningIdentityLeaseTests: XCTestCase {
    private func row(in storage: Storage, date: Date = Date()) throws -> CertificatePair {
        let row = CertificatePair(context: storage.context)
        row.uuid = UUID().uuidString
        row.nickname = "Credential-free lease fixture"
        row.date = date
        row.expiration = .distantFuture
        row.revoked = false; row.ppQCheck = false; row.isDefault = false
        try storage.context.save()
        return row
    }

    private func removeTestPasswords(in storage: Storage) {
        for row in storage.getAllCertificates() {
            if let uuid = row.uuid {
                try? SecureSecretStore.delete("certificate.password." + uuid) // try? ok: unique test-only Keychain teardown
            }
        }
    }

    func testLeasedInventoryProtectsEveryRowIncludingProfilesOwnedByAnotherRow() throws {
        let storage = Storage(inMemory: true)
        defer { removeTestPasswords(in: storage) }
        _ = try row(in: storage)
        _ = try row(in: storage, date: Date().addingTimeInterval(-1))
        let inputs = try SigningIdentityStore.snapshot(storage: storage)
        XCTAssertEqual(inputs.count, 2)
        let keys = inputs.map { SigningIdentityStore.leaseKey(reference: $0.reference) }
        do {
            let leased = try SigningIdentityStore.leasedSnapshot(storage: storage)
            try withExtendedLifetime(leased.leases) {
                XCTAssertEqual(leased.inputs.map(\.reference), inputs.map(\.reference))
                for key in keys {
                    XCTAssertTrue(AppOperationRegistry.shared.isBusy(key))
                    XCTAssertThrowsError(try AppOperationRegistry.shared.acquire(key))
                }
                XCTAssertNil(AppOperationRegistry.shared.acquireCleanup())
            }
        }
        for key in keys { XCTAssertFalse(AppOperationRegistry.shared.isBusy(key)) }
    }

    func testFailureToLeaseOneRowReleasesEveryEarlierAcquisition() throws {
        let storage = Storage(inMemory: true)
        defer { removeTestPasswords(in: storage) }
        _ = try row(in: storage)
        _ = try row(in: storage, date: Date().addingTimeInterval(-1))
        let inputs = try SigningIdentityStore.snapshot(storage: storage)
        let blocked = try XCTUnwrap(inputs.last)
        let key = SigningIdentityStore.leaseKey(reference: blocked.reference)
        let conflict = try AppOperationRegistry.shared.acquire(key)
        try withExtendedLifetime(conflict) {
            XCTAssertThrowsError(try SigningIdentityStore.leasedSnapshot(storage: storage))
            for input in inputs where input.reference != blocked.reference {
                XCTAssertFalse(AppOperationRegistry.shared.isBusy(SigningIdentityStore.leaseKey(reference: input.reference)))
            }
            XCTAssertTrue(AppOperationRegistry.shared.isBusy(key))
        }
    }

    func testBothCertificateDeletionOwnersRefuseALiveSigningIdentityLease() throws {
        let storage = Storage(inMemory: true), certificate = try row(in: storage)
        let reference = certificate.objectID.uriRepresentation().absoluteString
        let lease = try AppOperationRegistry.shared.acquire(SigningIdentityStore.leaseKey(reference: reference))
        withExtendedLifetime(lease) {
            XCTAssertFalse(storage.deleteCertificate(for: certificate))
            XCTAssertFalse(CertificateRemoval.delete(certificate, storage: storage))
            XCTAssertFalse(certificate.isDeleted)
            XCTAssertEqual(storage.getAllCertificates().count, 1)
        }
    }

    func testChangingTheKeychainPasswordAfterPreparationInvalidatesTheRunSnapshot() throws {
        let storage = Storage(inMemory: true)
        defer { removeTestPasswords(in: storage) }
        let certificate = try row(in: storage)
        try certificate.setSigningPassword("first synthetic password")
        try storage.context.save()
        let inputs = try SigningIdentityStore.snapshot(storage: storage)
        let references = Set(inputs.map(\.reference))
        XCTAssertNoThrow(try SigningIdentityStore.requireCurrent(references, matching: inputs, storage: storage))
        try certificate.setSigningPassword("different synthetic password")
        XCTAssertThrowsError(try SigningIdentityStore.requireCurrent(references, matching: inputs, storage: storage))
        XCTAssertThrowsError(try SigningIdentityStore.requireCurrent(references, matching: [], storage: storage))
        certificate.revoked = true
        XCTAssertThrowsError(try SigningIdentityStore.requireCurrent(references, storage: storage))
    }

    func testIdentityOwnershipCannotBeConfusedWithAStoredAppOfTheSameUUID() throws {
        let value = UUID().uuidString
        let reference = "x-coredata://test/CertificatePair/" + value
        let key = SigningIdentityStore.leaseKey(reference: reference)
        let lease = try AppOperationRegistry.shared.acquire(key)
        withExtendedLifetime(lease) {
            XCTAssertTrue(AppOperationRegistry.shared.isBusy(key))
            XCTAssertFalse(AppOperationRegistry.shared.isBusy("signed:" + value))
            XCTAssertFalse(AppOperationRegistry.shared.isBusy("imported:" + value))
        }
    }
}
