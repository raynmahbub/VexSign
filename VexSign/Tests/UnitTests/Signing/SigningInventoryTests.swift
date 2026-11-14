import CoreData
import Security
import XCTest
@testable import VexSign

@MainActor
final class SigningInventoryTests: XCTestCase {
    private func certificate(in storage: Storage) throws -> CertificatePair {
        let row = CertificatePair(context: storage.context)
        row.uuid = UUID().uuidString; row.nickname = "Synthetic inventory"
        row.date = Date(); row.expiration = .distantFuture
        row.revoked = false; row.ppQCheck = false; row.isDefault = false
        try storage.context.save()
        return row
    }

    private func cleanup(_ rows: [CertificatePair], in storage: Storage) {
        for row in rows {
            if let directory = storage.getUuidDirectory(for: row) {
                try? FileManager.default.removeItem(at: directory) // try? ok: unique test-created inventory only
            }
            if let uuid = row.uuid {
                try? SecureSecretStore.delete("certificate.password." + uuid) // try? ok: unique test-only Keychain item
            }
        }
    }

    func testSnapshotIncludesPrimaryAndAdditionalProfilesWithoutClaimingAuthentication() throws {
        let storage = Storage(inMemory: true), row = try certificate(in: storage)
        defer { cleanup([row], in: storage) }
        let root = try XCTUnwrap(storage.getUuidDirectory(for: row))
        let additional = root.appendingPathComponent(AdditionalProfiles.folderName)
        try FileManager.default.createDirectory(at: additional, withIntermediateDirectories: true)
        let p12 = root.appendingPathComponent("identity.P12")
        try Data("Not a signing identity".utf8).write(to: p12)
        let profiles = [root.appendingPathComponent("main.MOBILEPROVISION"), additional.appendingPathComponent("widget.mobileprovision")]
        for profile in profiles { try Data("Not an authenticated profile".utf8).write(to: profile) }
        try Data("ignored".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let input = try XCTUnwrap(SigningIdentityStore.snapshot(storage: storage).first)
        XCTAssertEqual(input.reference, row.objectID.uriRepresentation().absoluteString)
        XCTAssertEqual(input.p12URL, p12)
        XCTAssertEqual(Set(input.profileURLs), Set(profiles))
        XCTAssertNil(input.notice)
        XCTAssertEqual(input.password, "", "An explicit empty password is not an inaccessible Keychain.")
        XCTAssertThrowsError(try SigningIdentityStore.inspect(CertificateInputReader.read(p12), password: input.password))
        for url in input.profileURLs { XCTAssertThrowsError(try ProvisioningProfileParser.parse(CertificateInputReader.read(url))) }
    }

    func testMultiplePKCS12FilesRefuseThatRowWithoutHidingAnotherInventoryRow() throws {
        let storage = Storage(inMemory: true)
        let broken = try certificate(in: storage), healthy = try certificate(in: storage)
        defer { cleanup([broken, healthy], in: storage) }
        let directory = try XCTUnwrap(storage.getUuidDirectory(for: broken))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["first.p12", "second.P12"] { try Data([0]).write(to: directory.appendingPathComponent(name)) }
        let values = try SigningIdentityStore.snapshot(storage: storage)
        XCTAssertEqual(values.count, 2)
        let rejected = try XCTUnwrap(values.first { $0.reference == broken.objectID.uriRepresentation().absoluteString })
        XCTAssertNil(rejected.p12URL)
        XCTAssertTrue(rejected.profileURLs.isEmpty)
        XCTAssertTrue(rejected.notice?.contains("More than one identity") == true)
        XCTAssertNotNil(values.first { $0.reference == healthy.objectID.uriRepresentation().absoluteString })
    }

    func testLinkedAdditionalProfileDirectoryCannotContributePartialInventory() throws {
        let storage = Storage(inMemory: true), row = try certificate(in: storage)
        defer { cleanup([row], in: storage) }
        let root = try XCTUnwrap(storage.getUuidDirectory(for: row))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0]).write(to: root.appendingPathComponent("identity.p12"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(AdditionalProfiles.folderName),
            withDestinationURL: FileManager.default.temporaryDirectory)
        let input = try XCTUnwrap(SigningIdentityStore.snapshot(storage: storage).first)
        XCTAssertNil(input.p12URL)
        XCTAssertTrue(input.profileURLs.isEmpty)
        XCTAssertNotNil(input.notice)
    }

    func testTraversalUUIDIsNotResolvedAsAPathOrKeychainAccount() throws {
        let storage = Storage(inMemory: true), row = try certificate(in: storage)
        row.uuid = "../not-a-certificate"; try storage.context.save()
        let input = try XCTUnwrap(SigningIdentityStore.snapshot(storage: storage).first)
        XCTAssertNil(input.p12URL)
        XCTAssertNil(input.password)
        XCTAssertTrue(input.profileURLs.isEmpty)
        XCTAssertNotNil(input.notice)
    }

    func testUnavailablePasswordStaysNilWithoutHidingOtherRowsOrLeakingUnderlyingErrors() throws {
        let storage = Storage(inMemory: true)
        let blocked = try certificate(in: storage), healthy = try certificate(in: storage)
        let secretMarker = "synthetic-private-error-payload"
        let inputs = try SigningIdentityStore.snapshot(storage: storage, passwordReader: { row in
            if row.objectID == blocked.objectID {
                throw NSError(domain: secretMarker, code: Int(errSecInteractionNotAllowed),
                    userInfo: [NSLocalizedDescriptionKey: secretMarker])
            }
            return "healthy synthetic password"
        })
        XCTAssertEqual(inputs.count, 2)
        let rejected = try XCTUnwrap(inputs.first { $0.reference == blocked.objectID.uriRepresentation().absoluteString })
        XCTAssertNil(rejected.password, "Inaccessible is not an explicit empty password.")
        XCTAssertTrue(rejected.notice?.contains("Unlock the device") == true)
        XCTAssertFalse(rejected.notice?.contains(secretMarker) == true)
        let available = try XCTUnwrap(inputs.first { $0.reference == healthy.objectID.uriRepresentation().absoluteString })
        XCTAssertEqual(available.password, "healthy synthetic password")
        let references = Set([rejected.reference])
        XCTAssertThrowsError(try SigningIdentityStore.requireCurrent(references, matching: inputs, storage: storage,
            passwordReader: { _ in throw SecureSecretStore.Failure(status: errSecInteractionNotAllowed) }))
    }

    func testInvalidIdentityNeverReachesInjectedPasswordAccess() throws {
        let storage = Storage(inMemory: true), row = try certificate(in: storage)
        row.uuid = "../invalid"; try storage.context.save()
        var reads = 0
        let inputs = try SigningIdentityStore.snapshot(storage: storage, passwordReader: { _ in reads += 1; return "" })
        XCTAssertEqual(reads, 0)
        let reference = try XCTUnwrap(inputs.first?.reference)
        XCTAssertThrowsError(try SigningIdentityStore.requireCurrent(Set([reference]), storage: storage,
            passwordReader: { _ in reads += 1; return "" }))
        XCTAssertEqual(reads, 0)
    }

    func testOverLimitInventoryThrowsRatherThanSelectingATruncatedSubset() throws {
        let storage = Storage(inMemory: true)
        for _ in 0..<513 {
            let row = CertificatePair(context: storage.context)
            row.uuid = UUID().uuidString; row.date = Date()
            row.revoked = false; row.ppQCheck = false; row.isDefault = false
        }
        try storage.context.save()
        XCTAssertThrowsError(try SigningIdentityStore.snapshot(storage: storage))
    }
}
