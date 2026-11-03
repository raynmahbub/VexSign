import Foundation
import XCTest
import os
import Security
@testable import NativeSigningLinkSmoke

/// Written for later native execution; no Apple or actual Keychain operations.
final class NativeRegistrationExecutorTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private struct Store: NativeRegistrationStorage {
        struct State: Sendable { var row: NativeRegistrationRecord?; var failInsert = false; var failCommit = false }
        let lock = OSAllocatedUnfairLock(initialState: State())
        func read(owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) -> NativeRegistrationRecord? { lock.withLock { $0.row } }
        func insertIntent(_ record: NativeRegistrationRecord, owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws {
            try record.validate(owner: owner, subject: subject)
            try lock.withLock {
                guard $0.row == nil, !$0.failInsert else { throw NativeRegistrationError.storageUnavailable }
                $0.row = record
            }
        }
        func recordObservation(_ record: NativeRegistrationRecord, owner: NativeSigningIdentityOwner, subject: NativeRegistrationSubject) throws {
            try record.validate(owner: owner, subject: subject)
            try lock.withLock {
                guard $0.row?.id == record.id, $0.row?.phase == .uncertain, !$0.failCommit else { throw NativeRegistrationError.storageUnavailable }
                $0.row = record
            }
        }
    }
    private actor Portal: NativeRegistrationPortal {
        enum Mode: Equatable, Sendable { case success, timeout, invisible, duplicate }
        let store: Store
        let mode: Mode
        var sends = 0
        var sawIntent = false
        var initiallyExisting = false
        init(store: Store, mode: Mode, existing: Bool = false) { self.store = store; self.mode = mode; initiallyExisting = existing }
        func revalidateFreeAccount(owner: NativeSigningIdentityOwner, contextID: UUID) async throws {}
        func inventory(subject: NativeRegistrationSubject) async throws -> [NativeRegistrationObservation] {
            guard initiallyExisting || sends > 0 else { return [] }
            if mode == .invisible { return [] }
            let row = NativeRegistrationObservation(subject: subject, remoteIdentifier: "REMOTE1", enabled: true, expiresAt: nil)
            if mode == .duplicate { return [row, .init(subject: subject, remoteIdentifier: "REMOTE2", enabled: true, expiresAt: nil)] }
            return [row]
        }
        func registerOnce(subject: NativeRegistrationSubject, operationID: UUID) async throws {
            sends += 1; sawIntent = store.lock.withLock { $0.row?.phase == .uncertain }
            if mode == .timeout { throw URLError(.timedOut) }
        }
        func count() -> Int { sends }
        func intentObserved() -> Bool { sawIntent }
    }
    private typealias Executor = NativeRegistrationExecutor<Store, Portal>
    private static func owner() throws -> NativeSigningIdentityOwner { try .init(accountIdentifier: "123", dsid: "123", teamIdentifier: "ABCDE12345") }
    private static func subject() throws -> NativeRegistrationSubject { try .init(kind: .appID, value: "com.example.fixture") }
    private static var expires: Date { now.addingTimeInterval(900) }

    func testIntentIsPersistedBeforeOnlySendAndObservationCommitsForward() async throws {
        let store = Store(); let portal = Portal(store: store, mode: .success)
        let executor = Executor(store: store, portal: portal, clock: { Self.now })
        let owner = try Self.owner(); let subject = try Self.subject(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, subject: subject)
        let result = try await executor.execute(owner: owner, contextID: context, subject: subject, approval: grant, authorityExpiresAt: Self.expires, checkCurrent: {})
        XCTAssertEqual(result.remoteIdentifier, "REMOTE1")
        XCTAssertNotNil(result.operationID)
        let count = await portal.count(); XCTAssertEqual(count, 1)
        let sawIntent = await portal.intentObserved(); XCTAssertTrue(sawIntent)
        XCTAssertEqual(store.lock.withLock { $0.row?.phase }, .recorded)
        XCTAssertEqual(store.lock.withLock { $0.row?.remoteIdentifierDigest }, NativeSigningIdentityOwner.hash(Data("REMOTE1".utf8)))
    }

    func testIntentWriteFailurePreventsAnySend() async throws {
        let store = Store(); store.lock.withLock { $0.failInsert = true }
        let portal = Portal(store: store, mode: .success); let executor = Executor(store: store, portal: portal, clock: { Self.now })
        let owner = try Self.owner(); let subject = try Self.subject(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, subject: subject)
        do { _ = try await executor.execute(owner: owner, contextID: context, subject: subject, approval: grant, authorityExpiresAt: Self.expires, checkCurrent: {}); XCTFail("Durable intent required") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .storageUnavailable) }
        let count = await portal.count(); XCTAssertEqual(count, 0)
    }

    func testAmbiguousReplySurvivesRestartAndNeverResends() async throws {
        let store = Store(); let portal = Portal(store: store, mode: .invisible)
        let executor = Executor(store: store, portal: portal, clock: { Self.now })
        let owner = try Self.owner(); let subject = try Self.subject(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, subject: subject)
        do { _ = try await executor.execute(owner: owner, contextID: context, subject: subject, approval: grant, authorityExpiresAt: Self.expires, checkCurrent: {}); XCTFail("Not yet observable") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .reconciliationRequired) }
        let restarted = Executor(store: store, portal: portal, clock: { Self.now })
        do { _ = try await restarted.reconcile(owner: owner, contextID: context, subject: subject, authorityExpiresAt: Self.expires, checkCurrent: {}); XCTFail("Empty does not prove no mutation") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .reconciliationRequired) }
        let count = await portal.count(); XCTAssertEqual(count, 1)
        XCTAssertEqual(store.lock.withLock { $0.row?.phase }, .uncertain)
    }

    func testTimeoutCanRecoverReadOnlyWithoutReissuingRegistration() async throws {
        let store = Store(); let portal = Portal(store: store, mode: .timeout)
        let executor = Executor(store: store, portal: portal, clock: { Self.now })
        let owner = try Self.owner(); let subject = try Self.subject(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, subject: subject)
        do { _ = try await executor.execute(owner: owner, contextID: context, subject: subject, approval: grant, authorityExpiresAt: Self.expires, checkCurrent: {}); XCTFail("Timeout") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .requestFailed) }
        _ = try await executor.reconcile(owner: owner, contextID: context, subject: subject, authorityExpiresAt: Self.expires, checkCurrent: {})
        let count = await portal.count(); XCTAssertEqual(count, 1)
        XCTAssertEqual(store.lock.withLock { $0.row?.phase }, .recorded)
    }

    func testPreExistingRegistrationDoesNotSendOrInventIntent() async throws {
        let store = Store(); let portal = Portal(store: store, mode: .success, existing: true)
        let executor = Executor(store: store, portal: portal, clock: { Self.now })
        let result = try await executor.reconcile(owner: Self.owner(), contextID: UUID(), subject: Self.subject(), authorityExpiresAt: Self.expires, checkCurrent: {})
        XCTAssertNil(result.operationID)
        XCTAssertNil(store.lock.withLock { $0.row })
        let count = await portal.count(); XCTAssertEqual(count, 0)
    }

    func testDuplicateInventoryCannotBeArbitrarilyAdopted() async throws {
        let store = Store(); let portal = Portal(store: store, mode: .duplicate, existing: true)
        let executor = Executor(store: store, portal: portal, clock: { Self.now })
        do { _ = try await executor.reconcile(owner: Self.owner(), contextID: UUID(), subject: Self.subject(), authorityExpiresAt: Self.expires, checkCurrent: {}); XCTFail("Ambiguous inventory") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .inventoryRejected) }
        let count = await portal.count(); XCTAssertEqual(count, 0)
    }

    func testRevokedApprovalAndWrongContextCannotSend() async throws {
        let store = Store(); let portal = Portal(store: store, mode: .success)
        let executor = Executor(store: store, portal: portal, clock: { Self.now })
        let owner = try Self.owner(); let subject = try Self.subject(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, subject: subject)
        do { _ = try await executor.execute(owner: owner, contextID: UUID(), subject: subject, approval: grant, authorityExpiresAt: Self.expires, checkCurrent: {}); XCTFail("Context binding") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .approvalRequired) }
        let next = try await executor.approve(owner: owner, contextID: context, subject: subject)
        await executor.revoke()
        do { _ = try await executor.execute(owner: owner, contextID: context, subject: subject, approval: next, authorityExpiresAt: Self.expires, checkCurrent: {}); XCTFail("Revoked") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .approvalRequired) }
        let count = await portal.count(); XCTAssertEqual(count, 0)
    }

    func testResourceHashFoldsCaseButApprovalRemainsExact() throws {
        let a = try NativeRegistrationSubject(kind: .appID, value: "com.example.App")
        let b = try NativeRegistrationSubject(kind: .appID, value: "com.example.app")
        XCTAssertEqual(a.digest, b.digest) // cannot bypass pending intent by case
        XCTAssertNotEqual(a.approvalDigest, b.approvalDigest)
        XCTAssertEqual(a.description, "NativeRegistrationSubject(redacted)")
        XCTAssertThrowsError(try NativeRegistrationSubject(kind: .appID, value: "com.example.*"))
        XCTAssertThrowsError(try NativeRegistrationSubject(kind: .device, value: "vendor-id"))
    }
    func testCommitFailureRetainsUncertainMarkerForReadOnlyRecovery() async throws {
        let store = Store(); store.lock.withLock { $0.failCommit = true }
        let portal = Portal(store: store, mode: .success)
        let executor = Executor(store: store, portal: portal, clock: { Self.now })
        let owner = try Self.owner(); let subject = try Self.subject(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, subject: subject)
        do { _ = try await executor.execute(owner: owner, contextID: context, subject: subject, approval: grant, authorityExpiresAt: Self.expires, checkCurrent: {}); XCTFail("Commit unavailable") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .storageUnavailable) }
        XCTAssertEqual(store.lock.withLock { $0.row?.phase }, .uncertain)
        store.lock.withLock { $0.failCommit = false }
        _ = try await executor.reconcile(owner: owner, contextID: context, subject: subject, authorityExpiresAt: Self.expires, checkCurrent: {})
        let count = await portal.count(); XCTAssertEqual(count, 1)
    }

    func testApprovalCannotBeReplayedOrRenewedOverKnownIntent() async throws {
        let store = Store(); let portal = Portal(store: store, mode: .success)
        let executor = Executor(store: store, portal: portal, clock: { Self.now })
        let owner = try Self.owner(); let subject = try Self.subject(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, subject: subject)
        _ = try await executor.execute(owner: owner, contextID: context, subject: subject, approval: grant, authorityExpiresAt: Self.expires, checkCurrent: {})
        do { _ = try await executor.execute(owner: owner, contextID: context, subject: subject, approval: grant, authorityExpiresAt: Self.expires, checkCurrent: {}); XCTFail("Single use") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .approvalRequired) }
        do { _ = try await executor.approve(owner: owner, contextID: context, subject: subject); XCTFail("Reconcile existing intent") }
        catch { XCTAssertEqual(error as? NativeRegistrationError, .reconciliationRequired) }
        let count = await portal.count(); XCTAssertEqual(count, 1)
    }

    func testExplicitDeviceSubjectUsesSameDurableOrdering() async throws {
        let store = Store(); let portal = Portal(store: store, mode: .success)
        let executor = Executor(store: store, portal: portal, clock: { Self.now })
        let owner = try Self.owner(); let subject = try NativeRegistrationSubject(kind: .device, value: "0000ABCD-0011223344556677"); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, subject: subject)
        _ = try await executor.execute(owner: owner, contextID: context, subject: subject, approval: grant, authorityExpiresAt: Self.expires, checkCurrent: {})
        let sawIntent = await portal.intentObserved(); XCTAssertTrue(sawIntent)
        let count = await portal.count(); XCTAssertEqual(count, 1)
    }

    private final class KeychainClient: AppleAccountJournalKeychainClient {
        var attributes: [String: Any] = [:]
        var lastQuery: [String: Any] = [:]
        var status: OSStatus = errSecSuccess
        func add(_ attributes: [String: Any]) -> OSStatus {
            guard self.attributes.isEmpty else { return errSecDuplicateItem }
            self.attributes = attributes; return status
        }
        func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
            lastQuery = query
            return (status, attributes[kSecValueData as String] as? Data)
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            lastQuery = query
            guard query[kSecAttrGeneric as String] as? Data == self.attributes[kSecAttrGeneric as String] as? Data,
                  query[kSecAttrLabel as String] as? String == self.attributes[kSecAttrLabel as String] as? String else { return errSecItemNotFound }
            self.attributes.merge(attributes) { _, new in new }; return status
        }
        func delete(_ query: [String: Any]) -> OSStatus { XCTFail("No registration reset/delete path"); return errSecParam }
    }

    func testKeychainJournalIsDeviceOnlyAndCommitIsUUIDPhaseConditional() throws {
        let client = KeychainClient(); let store = NativeRegistrationKeychainStore(client: client)
        let owner = try Self.owner(); let subject = try NativeRegistrationSubject(kind: .device, value: "0000ABCD-0011223344556677")
        var row = NativeRegistrationRecord(schema: 1, id: UUID(), ownerDigest: owner.digest, subjectDigest: subject.digest,
            createdAt: Self.now, phase: .uncertain, remoteIdentifierDigest: nil)
        try store.insertIntent(row, owner: owner, subject: subject)
        XCTAssertEqual(client.attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(client.attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(client.attributes[kSecAttrAccessGroup as String])
        let bytes = try XCTUnwrap(client.attributes[kSecValueData as String] as? Data)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(subject.value))
        row.phase = .recorded; row.remoteIdentifierDigest = NativeSigningIdentityOwner.hash(Data(subject.value.utf8))
        try store.recordObservation(row, owner: owner, subject: subject)
        XCTAssertEqual(client.lastQuery[kSecAttrLabel as String] as? String, "uncertain")
        XCTAssertEqual(client.lastQuery[kSecAttrGeneric as String] as? Data, Data(row.id.uuidString.utf8))
        XCTAssertThrowsError(try store.recordObservation(row, owner: owner, subject: subject))
    }

    func testKeychainErrorsAndCorruptionNeverMeanAbsent() throws {
        let client = KeychainClient(); let store = NativeRegistrationKeychainStore(client: client)
        client.status = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.read(owner: Self.owner(), subject: Self.subject())) {
            XCTAssertEqual($0 as? NativeRegistrationError, .storageUnavailable)
        }
        client.status = errSecSuccess; client.attributes[kSecValueData as String] = Data("{\"schema\":99}".utf8)
        XCTAssertThrowsError(try store.read(owner: Self.owner(), subject: Self.subject())) {
            XCTAssertEqual($0 as? NativeRegistrationError, .invalidJournal)
        }
        client.status = errSecItemNotFound
        XCTAssertNil(try store.read(owner: Self.owner(), subject: Self.subject()))
    }

}
