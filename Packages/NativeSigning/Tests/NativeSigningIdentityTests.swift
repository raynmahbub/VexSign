import Foundation
import Security
import XCTest
import os
@testable import NativeSigningLinkSmoke

/// Coding-phase fixtures. No real Keychain or portal calls. Execution deferred.
final class NativeSigningIdentityTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private struct Store: NativeSigningIdentityStorage {
        struct State: Sendable {
            var records: [String: NativeSigningIdentityRecord] = [:]
            var failReplacement = false
            var writes = 0
        }
        let lock = OSAllocatedUnfairLock(initialState: State())
        func read(owner: NativeSigningIdentityOwner) throws -> NativeSigningIdentityRecord? {
            lock.withLock { $0.records[owner.digest] }
        }
        func insert(_ record: NativeSigningIdentityRecord, owner: NativeSigningIdentityOwner) throws {
            try lock.withLock {
                guard $0.records[owner.digest] == nil else { throw NativeSigningIdentityError.storageUnavailable }
                $0.records[owner.digest] = record; $0.writes += 1
            }
        }
        func replace(_ record: NativeSigningIdentityRecord, owner: NativeSigningIdentityOwner) throws {
            try lock.withLock {
                guard !$0.failReplacement, let previous = $0.records[owner.digest], previous.id == record.id,
                      (previous.phase == .prepared && record.phase == .submissionUncertain)
                        || (previous.phase == .submissionUncertain && record.phase == .certificateRecorded) else {
                    throw NativeSigningIdentityError.storageUnavailable
                }
                $0.records[owner.digest] = record; $0.writes += 1
            }
        }
        func deletePrepared(_ record: NativeSigningIdentityRecord, owner: NativeSigningIdentityOwner) throws {
            try lock.withLock {
                guard let existing = $0.records[owner.digest], existing.id == record.id, existing.phase == .prepared else {
                    throw NativeSigningIdentityError.cannotDiscardSubmittedIdentity
                }
                $0.records.removeValue(forKey: owner.digest)
            }
        }
    }
    /// Synthetic bytes for state transitions only; not claimed to be a valid CSR.
    private struct Generator: NativeSigningIdentityGenerating {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        func generate(owner: NativeSigningIdentityOwner, id: UUID, now: Date) throws -> NativeSigningIdentityRecord {
            calls.withLock { $0 += 1 }
            return NativeSigningIdentityRecord(schema: 1, ownerDigest: owner.digest, teamIdentifier: owner.teamIdentifier,
                id: id, createdAt: now, privateKeyDER: Data([1]), publicKeyDER: Data([2]), csrDER: Data([3]),
                phase: .prepared, certificateDER: nil, certificateIdentifier: nil)
        }
    }
    private func owner(_ account: String = "123", team: String = "TEAM") throws -> NativeSigningIdentityOwner {
        try NativeSigningIdentityOwner(accountIdentifier: account, dsid: account, teamIdentifier: team)
    }

    // Synthetic grant binding only. These bytes are not a trusted certificate
    // and these tests do not export a real key or authorize signing.
    func testKeyExportGrantIsConsumedExactlyOnce() async throws {
        let gate = NativeKeyExportConsentGate(), owner = try owner(), identity = UUID(), flow = UUID()
        let certificate = Data([1, 2, 3])
        let grant = try await gate.recordExplicitConsent(owner: owner, identityID: identity,
            certificate: certificate, flow: flow, now: Self.now, lifetime: 120)
        try await gate.begin(grant, owner: owner, identityID: identity, certificate: certificate, flow: flow, now: Self.now)
        do {
            try await gate.begin(grant, owner: owner, identityID: identity, certificate: certificate, flow: flow, now: Self.now)
            XCTFail("Consumed export grant must not permit replay")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .creationApprovalRequired) }
    }

    func testKeyExportGrantRejectsRevocationWrongFlowAndExpiry() async throws {
        let owner = try owner(), identity = UUID(), flow = UUID(), certificate = Data([1])
        for variant in 0..<3 {
            let gate = NativeKeyExportConsentGate()
            let grant = try await gate.recordExplicitConsent(owner: owner, identityID: identity,
                certificate: certificate, flow: flow, now: Self.now, lifetime: 120)
            if variant == 0 { await gate.revoke() }
            do {
                try await gate.begin(grant, owner: owner, identityID: identity, certificate: certificate,
                    flow: variant == 1 ? UUID() : flow,
                    now: variant == 2 ? Self.now.addingTimeInterval(120) : Self.now)
                XCTFail("Revoked, stale-flow and expired grants must fail closed")
            } catch {
                XCTAssertEqual(error as? NativeSigningIdentityError, variant == 2 ? .invalidRecord : .creationApprovalRequired)
            }
        }
    }

    func testKeyExportGateMatchesEntireGrantAndRejectsReplacedGrant() async throws {
        let gate = NativeKeyExportConsentGate(), owner = try owner(), identity = UUID(), flow = UUID()
        let certificate = Data([1])
        let old = try await gate.recordExplicitConsent(owner: owner, identityID: identity,
            certificate: certificate, flow: flow, now: Self.now, lifetime: 120)
        let current = try await gate.recordExplicitConsent(owner: owner, identityID: identity,
            certificate: certificate, flow: flow, now: Self.now, lifetime: 120)
        let altered = NativeKeyExportConsent(id: current.id, ownerDigest: current.ownerDigest,
            identityID: current.identityID, certificateSHA256: current.certificateSHA256,
            flow: current.flow, epoch: current.epoch, expiresAt: current.expiresAt.addingTimeInterval(1))
        for grant in [old, altered] {
            do {
                try await gate.begin(grant, owner: owner, identityID: identity, certificate: certificate, flow: flow, now: Self.now)
                XCTFail("Replaced or modified grant must not consume the current exact grant")
            } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .creationApprovalRequired) }
        }
        try await gate.begin(current, owner: owner, identityID: identity, certificate: certificate, flow: flow, now: Self.now)
    }

    func testKeyExportBindingFailureBurnsGrantBeforeAnyRetry() async throws {
        let gate = NativeKeyExportConsentGate(), owner = try owner(), identity = UUID(), flow = UUID()
        let certificate = Data([1])
        let grant = try await gate.recordExplicitConsent(owner: owner, identityID: identity,
            certificate: certificate, flow: flow, now: Self.now, lifetime: 120)
        do {
            try await gate.begin(grant, owner: owner, identityID: identity, certificate: Data([2]), flow: flow, now: Self.now)
            XCTFail("Changed certificate must fail binding")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .invalidRecord) }
        do {
            try await gate.begin(grant, owner: owner, identityID: identity, certificate: certificate, flow: flow, now: Self.now)
            XCTFail("A failed binding check must not leave a reusable export grant")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .creationApprovalRequired) }
    }

    func testLocalInventoryDoesNotPrepareMissingIdentityOrMutateExistingOne() async throws {
        let store = Store(), generator = Generator()
        let owner = try owner()
        let coordinator = NativeSigningIdentityCoordinator(store: store, generator: generator)
        let inventory: any NativeSigningIdentityManaging = coordinator
        let missing = try await inventory.localIdentity(owner: owner, now: Self.now)
        XCTAssertNil(missing)
        XCTAssertEqual(generator.calls.withLock { $0 }, 0)
        XCTAssertEqual(store.lock.withLock { $0.writes }, 0)
        let prepared = try await coordinator.prepare(owner: owner, now: Self.now)
        let info = try await inventory.localIdentity(owner: owner, now: Self.now)
        XCTAssertEqual(info?.ticket, prepared)
        XCTAssertNil(info?.certificateSHA256)
        XCTAssertNil(info?.certificateExpiresAt)
        XCTAssertEqual(generator.calls.withLock { $0 }, 1)
        XCTAssertEqual(store.lock.withLock { $0.writes }, 1)
        let other = try self.owner("other")
        let otherInfo = try await coordinator.localIdentity(owner: other, now: Self.now)
        XCTAssertNil(otherInfo)
    }

    func testLocalInventoryRejectsFutureCreationWithoutRotation() async throws {
        let store = Store(), generator = Generator()
        let owner = try owner()
        let coordinator = NativeSigningIdentityCoordinator(store: store, generator: generator)
        _ = try await coordinator.prepare(owner: owner, now: Self.now)
        do {
            _ = try await coordinator.localIdentity(owner: owner, now: Self.now.addingTimeInterval(-1))
            XCTFail("Future local identity must fail closed")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .invalidRecord) }
        XCTAssertEqual(generator.calls.withLock { $0 }, 1)
        XCTAssertEqual(store.lock.withLock { $0.writes }, 1)
    }

    func testProfileProjectionRejectsPreparedAndUncertainRowsWithoutMutation() async throws {
        let store = Store(); let owner = try owner(team: "ABCDE12345"); let generator = Generator()
        let coordinator = NativeSigningIdentityCoordinator(store: store, generator: generator)
        let ticket = try await coordinator.prepare(owner: owner, now: Self.now)
        for phase in [NativeSigningIdentityPhase.prepared, .submissionUncertain] {
            if phase == .submissionUncertain { _ = try await coordinator.beginSubmission(owner: owner, identityID: ticket.id) }
            do {
                _ = try await coordinator.profileValidationRequest(owner: owner, identityID: ticket.id,
                    bundleIdentifier: "com.example.fixture", deviceIdentifier: "0000ABCD-0011223344556677", now: Self.now)
                XCTFail("A recorded, matching certificate is required")
            } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .reconciliationRequired) }
            XCTAssertEqual(try store.read(owner: owner)?.phase, phase)
        }
        XCTAssertEqual(generator.calls.withLock { $0 }, 1)
    }

    func testProfileProjectionRevalidatesStoredCryptographicMaterial() async throws {
        let store = Store(); let owner = try owner(team: "ABCDE12345")
        let coordinator = NativeSigningIdentityCoordinator(store: store, generator: Generator())
        let ticket = try await coordinator.prepare(owner: owner, now: Self.now)
        store.lock.withLock {
            $0.records[owner.digest]?.phase = .certificateRecorded
            $0.records[owner.digest]?.certificateIdentifier = "CERT"
            $0.records[owner.digest]?.certificateDER = Data([0x30, 0x01, 0x00])
        }
        do {
            _ = try await coordinator.profileValidationRequest(owner: owner, identityID: ticket.id,
                bundleIdentifier: "com.example.fixture", deviceIdentifier: "0000ABCD-0011223344556677", now: Self.now)
            XCTFail("Synthetic bytes must not become ownership evidence")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .invalidRecord) }
        XCTAssertEqual(try store.read(owner: owner)?.phase, .certificateRecorded)
    }

    func testRestartAndRetryReuseOwnedIdentity() async throws {
        let store = Store(); let generator = Generator(); let owner = try owner()
        let first = NativeSigningIdentityCoordinator(store: store, generator: generator)
        let ticket = try await first.prepare(owner: owner, now: Self.now)
        let restarted = NativeSigningIdentityCoordinator(store: store, generator: generator)
        let recovered = try await restarted.prepare(owner: owner, now: Self.now)
        XCTAssertEqual(ticket, recovered)
        XCTAssertEqual(generator.calls.withLock { $0 }, 1)
    }

    func testUncertainIntentIsDurableBeforeCSRReturnsAndCannotBeRetried() async throws {
        let store = Store(); let owner = try owner()
        let coordinator = NativeSigningIdentityCoordinator(store: store, generator: Generator())
        let ticket = try await coordinator.prepare(owner: owner, now: Self.now)
        let submission = try await coordinator.beginSubmission(owner: owner, identityID: ticket.id)
        XCTAssertEqual(submission.identityID, ticket.id)
        XCTAssertEqual(try store.read(owner: owner)?.phase, .submissionUncertain)
        do { _ = try await coordinator.beginSubmission(owner: owner, identityID: ticket.id); XCTFail("No duplicate submit") }
        catch { XCTAssertEqual(error as? NativeSigningIdentityError, .reconciliationRequired) }
        let recovered = try await coordinator.prepare(owner: owner, now: Self.now)
        XCTAssertEqual(recovered.phase, .submissionUncertain)
        XCTAssertEqual(recovered.id, ticket.id)
    }

    func testFailedIntentWriteDoesNotReleaseCSR() async throws {
        let store = Store(); let owner = try owner()
        let coordinator = NativeSigningIdentityCoordinator(store: store, generator: Generator())
        let ticket = try await coordinator.prepare(owner: owner, now: Self.now)
        store.lock.withLock { $0.failReplacement = true }
        do { _ = try await coordinator.beginSubmission(owner: owner, identityID: ticket.id); XCTFail("Must persist first") }
        catch { XCTAssertEqual(error as? NativeSigningIdentityError, .storageUnavailable) }
        XCTAssertEqual(try store.read(owner: owner)?.phase, .prepared)
    }

    func testOnlyNeverSubmittedDraftCanBeDiscarded() async throws {
        let store = Store(); let owner = try owner()
        let coordinator = NativeSigningIdentityCoordinator(store: store, generator: Generator())
        let first = try await coordinator.prepare(owner: owner, now: Self.now)
        try await coordinator.discardPrepared(owner: owner, identityID: first.id)
        let second = try await coordinator.prepare(owner: owner, now: Self.now)
        XCTAssertNotEqual(first.id, second.id)
        _ = try await coordinator.beginSubmission(owner: owner, identityID: second.id)
        do { try await coordinator.discardPrepared(owner: owner, identityID: second.id); XCTFail("Keep uncertain key") }
        catch { XCTAssertEqual(error as? NativeSigningIdentityError, .cannotDiscardSubmittedIdentity) }
    }

    func testWrongOperationAndRejectedCertificatePreserveUncertainRow() async throws {
        let store = Store(); let owner = try owner()
        let coordinator = NativeSigningIdentityCoordinator(store: store, generator: Generator())
        let ticket = try await coordinator.prepare(owner: owner, now: Self.now)
        do { _ = try await coordinator.beginSubmission(owner: owner, identityID: UUID()); XCTFail("Wrong operation") }
        catch { XCTAssertEqual(error as? NativeSigningIdentityError, .identityChanged) }
        _ = try await coordinator.beginSubmission(owner: owner, identityID: ticket.id)
        do {
            _ = try await coordinator.recordCertificate(owner: owner, identityID: ticket.id,
                certificateDER: Data([0]), certificateIdentifier: "CERT", now: Self.now)
            XCTFail("Reject unbound certificate")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .certificateRejected) }
        XCTAssertEqual(try store.read(owner: owner)?.phase, .submissionUncertain)
    }

    func testMissingCertificateAfterUncertainSubmissionNeverResetsOrResubmits() async throws {
        let store = Store(); let owner = try owner()
        let coordinator = NativeSigningIdentityCoordinator(store: store, generator: Generator())
        let ticket = try await coordinator.prepare(owner: owner, now: Self.now)
        _ = try await coordinator.beginSubmission(owner: owner, identityID: ticket.id)
        do {
            _ = try await coordinator.reconcileUncertain(owner: owner, identityID: ticket.id, certificates: [], now: Self.now)
            XCTFail("Absence is not proof of no issue")
        } catch { XCTAssertEqual(error as? NativeSigningIdentityError, .reconciliationRequired) }
        XCTAssertEqual(try store.read(owner: owner)?.phase, .submissionUncertain)
        XCTAssertEqual(store.lock.withLock { $0.writes }, 2)
    }

    func testOwnerBindingSeparatesAccountAndTeamWithoutEmailLabel() throws {
        let a = try owner(); let b = try owner("456"); let c = try owner(team: "OTHER")
        XCTAssertNotEqual(a.digest, b.digest)
        XCTAssertNotEqual(a.digest, c.digest)
        XCTAssertEqual(a.digest.count, 64)
        XCTAssertEqual(a, try owner())
    }

    func testActualInMemoryRSAKeyAndCSRReconstructionRejectsTampering() throws {
        let owner = try owner()
        let record = try NativeSigningIdentityCrypto().generate(owner: owner, id: UUID(), now: Self.now)
        try record.validateShape(owner: owner)
        try NativeSigningIdentityCrypto.validateMaterial(record)
        XCTAssertFalse(String(reflecting: record).contains(record.privateKeyDER.base64EncodedString()))
        let corrupt = NativeSigningIdentityRecord(schema: record.schema, ownerDigest: record.ownerDigest,
            teamIdentifier: record.teamIdentifier, id: record.id, createdAt: record.createdAt,
            privateKeyDER: record.privateKeyDER, publicKeyDER: record.publicKeyDER, csrDER: record.csrDER + Data([0]),
            phase: record.phase, certificateDER: nil, certificateIdentifier: nil)
        XCTAssertThrowsError(try NativeSigningIdentityCrypto.validateMaterial(corrupt))
    }

    private final class Client: AppleAccountJournalKeychainClient, @unchecked Sendable {
        var inserted: [String: Any] = [:]
        var lastQuery: [String: Any] = [:]
        var data: Data?
        var replacementStatus: OSStatus = errSecSuccess
        func add(_ attributes: [String: Any]) -> OSStatus {
            guard data == nil else { return errSecDuplicateItem }
            inserted = attributes; data = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
        func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
            (data == nil ? errSecItemNotFound : errSecSuccess, data)
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            lastQuery = query
            if replacementStatus == errSecSuccess { data = attributes[kSecValueData as String] as? Data }
            return replacementStatus
        }
        func delete(_ query: [String: Any]) -> OSStatus { lastQuery = query; return errSecItemNotFound }
    }

    func testDeviceOnlyVaultPolicyAndConditionalPhaseReplacement() throws {
        let client = Client(); let owner = try owner()
        let store = NativeSigningIdentityKeychainStore(client: client)
        var record = try NativeSigningIdentityCrypto().generate(owner: owner, id: UUID(), now: Self.now)
        try store.insert(record, owner: owner)
        XCTAssertEqual(client.inserted[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(client.inserted[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(client.inserted[kSecAttrAccessGroup as String])
        XCTAssertEqual(client.inserted[kSecAttrAccount as String] as? String, "owner." + owner.digest)
        XCTAssertEqual(try store.read(owner: owner)?.id, record.id)
        record.phase = .submissionUncertain
        try store.replace(record, owner: owner)
        XCTAssertEqual(client.lastQuery[kSecAttrLabel as String] as? String, NativeSigningIdentityPhase.prepared.rawValue)
        XCTAssertEqual(client.lastQuery[kSecAttrGeneric as String] as? Data, Data(record.id.uuidString.utf8))
    }

    func testVaultDoesNotResetUnknownOrCorruptRecord() throws {
        let client = Client(); let store = NativeSigningIdentityKeychainStore(client: client)
        client.data = Data("{\"schema\":99}".utf8)
        XCTAssertThrowsError(try store.read(owner: owner())) {
            XCTAssertEqual($0 as? NativeSigningIdentityError, .invalidRecord)
        }
        XCTAssertTrue(client.inserted.isEmpty)
    }
}
