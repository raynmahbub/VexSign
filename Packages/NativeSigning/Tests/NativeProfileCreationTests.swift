import Foundation
import XCTest
import os
import Security
@testable import NativeSigningLinkSmoke

/// Synthetic policy/state fixtures. Mock verification is NOT real Apple CMS trust.
final class NativeProfileCreationTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private static let team = "ABCDE12345"
    private static let bundle = "com.example.fixture"
    private static let udid = "0000ABCD-0011223344556677"
    private static let certificate = Data([0x30, 0x01, 0x00])
    private static let cms = Data("SYNTHETIC CMS".utf8)
    private struct Store: NativeProfileCreationStorage {
        struct State: Sendable { var row: NativeProfileCreationRecord?; var reads = 0; var failInsert = false; var failCommit = false }
        let lock = OSAllocatedUnfairLock(initialState: State())
        func read(owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) -> NativeProfileCreationRecord? {
            lock.withLock { $0.reads += 1; return $0.row }
        }
        func listAllRecords(owner: NativeSigningIdentityOwner) -> [NativeProfileCreationRecord] {
            lock.withLock { state in
                guard let row = state.row, row.ownerDigest == owner.digest else { return [] }
                return [row]
            }
        }
        func insertIntent(_ record: NativeProfileCreationRecord, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws {
            try record.validate(owner: owner, request: request)
            try lock.withLock {
                guard $0.row == nil, !$0.failInsert else { throw NativeProfileCreationError.storageUnavailable }; $0.row = record
            }
        }
        func recordObservation(_ record: NativeProfileCreationRecord, owner: NativeSigningIdentityOwner, request: NativeProfileCreationRequest) throws {
            try record.validate(owner: owner, request: request)
            try lock.withLock {
                guard $0.row?.id == record.id, $0.row?.phase == .uncertain, !$0.failCommit else { throw NativeProfileCreationError.storageUnavailable }; $0.row = record
            }
        }
    }
    private struct Verifier: NativeProfileCMSVerifying {
        let payload: Data
        func verifyAppleProvisioningCMS(_ cms: Data, now: Date) async throws -> Data { payload }
    }
    private actor Portal: NativeProfileCreationPortal {
        let store: Store
        let timeout: Bool
        var sends = 0
        var reads = 0
        var sawIntent = false
        var visible = true
        var listedUUID: UUID?
        func substituteListedUUID() { listedUUID = UUID() }
        init(store: Store, timeout: Bool = false) { self.store = store; self.timeout = timeout }
        func hide() { visible = false }
        func revalidate(owner: NativeSigningIdentityOwner, contextID: UUID, request: NativeProfileCreationRequest) async throws { reads += 1 }
        func inventory(request: NativeProfileCreationRequest) async throws -> [NativeProfileObservation] {
            guard sends > 0, visible else { return [] }
            return [.init(remoteIdentifier: "PROFILE1", cms: NativeProfileCreationTests.cms, listedUUID: listedUUID)]
        }
        func createOnce(request: NativeProfileCreationRequest, operationID: UUID) async throws {
            sends += 1
            sawIntent = store.lock.withLock { $0.row?.id == operationID && $0.row?.phase == .uncertain }
            if timeout { throw URLError(.timedOut) }
        }
        func values() -> (Int, Int, Bool) { (sends, reads, sawIntent) }
    }
    private static func owner() throws -> NativeSigningIdentityOwner {
        try .init(accountIdentifier: "123", dsid: "123", teamIdentifier: team)
    }
    private static func request(bundle: String = "com.example.fixture", appID: String = "APP1", expectedUUID: UUID? = nil) throws -> NativeProfileCreationRequest {
        let validation = try NativeProfileValidationRequest(teamIdentifier: team, bundleIdentifier: bundle, deviceIdentifier: udid, certificateDER: certificate, expectedUUID: expectedUUID)
        return try .init(identityID: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!, validation: validation, appID: appID, deviceID: "DEVICE1", certificateID: "CERT1")
    }
    private static func validator(wrongTeam: Bool = false) throws -> NativeProvisioningProfileValidator {
        let root: [String: Any] = ["Version": 1, "UUID": "12345678-1234-1234-1234-123456789012",
            "CreationDate": now.addingTimeInterval(-60), "ExpirationDate": now.addingTimeInterval(3600), "Platform": ["iOS"],
            "TeamIdentifier": [wrongTeam ? "OTHER12345" : team], "ApplicationIdentifierPrefix": [team],
            "ProvisionedDevices": [udid], "DeveloperCertificates": [certificate],
            "Entitlements": ["application-identifier": team + "." + bundle, "com.apple.developer.team-identifier": team,
                             "get-task-allow": true, "keychain-access-groups": [team + ".*"]]]
        return NativeProvisioningProfileValidator(verifier: Verifier(payload: try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)))
    }

    private struct ReceiptClient: AppleAccountJournalKeychainClient, Sendable {
        struct State: Sendable {
            var rows: [String: Data] = [:]
            var status = errSecSuccess
            var deviceOnly = false
        }
        let lock = OSAllocatedUnfairLock(initialState: State())
        func add(_ attributes: [String: Any]) -> OSStatus {
            guard let key = attributes[kSecAttrAccount as String] as? String,
                  let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            let deviceOnly = (attributes[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            return lock.withLock {
                $0.deviceOnly = deviceOnly
                if $0.rows[key] != nil { return errSecDuplicateItem }
                $0.rows[key] = data
                return errSecSuccess
            }
        }
        func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
            guard let key = query[kSecAttrAccount as String] as? String else { return (errSecParam, nil) }
            return lock.withLock {
                guard let data = $0.rows[key] else { return (errSecItemNotFound, nil) }
                return ($0.status, data)
            }
        }
        func copyAll(_ query: [String: Any]) -> (status: OSStatus, items: [[String: Any]]) {
            let snapshot = lock.withLock { ($0.status, $0.rows) }
            return (snapshot.0, snapshot.1.map { [kSecAttrAccount as String: $0.key, kSecValueData as String: $0.value] })
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errSecUnimplemented }
        func delete(_ query: [String: Any]) -> OSStatus { errSecUnimplemented }
    }

    func testReceiptIndexRetainsRealIdentityAndDeviceWithoutChangingJournal() async throws {
        let owner = try Self.owner(), request = try Self.request()
        let profile = try await Self.validator().validate(cms: Self.cms, request: request.validation, now: Self.now)
        let receipt = try NativeProfileReceipt(profile: profile, owner: owner, request: request, recordedAt: Self.now)
        let client = ReceiptClient(), index = NativeProfileReceiptKeychainStore(client: client)
        try index.record(receipt, owner: owner)
        let observed = try XCTUnwrap(index.list(owner: owner).first)
        XCTAssertEqual(observed.identityID, request.identityID)
        XCTAssertEqual(observed.deviceIdentifier, Self.udid)
        XCTAssertEqual(observed.bundleIdentifier, Self.bundle)
        XCTAssertEqual(observed.cmsSHA256, NativeSigningIdentityOwner.hash(Self.cms))
        XCTAssertTrue(client.lock.withLock { $0.deviceOnly })
        XCTAssertFalse(String(describing: receipt).contains(Self.udid))
        // A later observation is idempotent, not a replacement or creation grant.
        try index.record(NativeProfileReceipt(profile: profile, owner: owner, request: request,
                                              recordedAt: Self.now.addingTimeInterval(1)), owner: owner)
        XCTAssertEqual(try index.list(owner: owner).count, 1)
    }

    func testReceiptIndexIsOwnerScopedAndFailsClosedWhenLocked() async throws {
        let owner = try Self.owner(), request = try Self.request()
        let profile = try await Self.validator().validate(cms: Self.cms, request: request.validation, now: Self.now)
        let receipt = try NativeProfileReceipt(profile: profile, owner: owner, request: request, recordedAt: Self.now)
        let client = ReceiptClient(), index = NativeProfileReceiptKeychainStore(client: client)
        try index.record(receipt, owner: owner)
        let other = try NativeSigningIdentityOwner(accountIdentifier: "other", dsid: "other", teamIdentifier: Self.team)
        XCTAssertEqual(try index.list(owner: other).count, 0)
        XCTAssertThrowsError(try receipt.validate(owner: other))
        client.lock.withLock { $0.status = errSecInteractionNotAllowed }
        XCTAssertThrowsError(try index.list(owner: owner))
    }

    func testReceiptIndexRejectsMislabeledOrUnknownSchemaData() async throws {
        let owner = try Self.owner(), request = try Self.request()
        let profile = try await Self.validator().validate(cms: Self.cms, request: request.validation, now: Self.now)
        let receipt = try NativeProfileReceipt(profile: profile, owner: owner, request: request, recordedAt: Self.now)
        let client = ReceiptClient(), index = NativeProfileReceiptKeychainStore(client: client)
        try index.record(receipt, owner: owner)
        try client.lock.withLock { state in
            let key = try XCTUnwrap(state.rows.keys.first)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: state.rows[key]!) as? [String: Any])
            object["unexpected"] = "not allowed"
            state.rows[key] = try JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertThrowsError(try index.list(owner: owner))
    }

    func testCMSCapabilityIsNotAutomaticallyPromoted() throws {
        XCTAssertFalse(NativeProvisioningProfileValidator().isConfigured)
        XCTAssertTrue(try Self.validator().isConfigured)
    }

    func testDefaultCMSGateBlocksApprovalAndRecoveryBeforeAnyIO() async throws {
        let store = Store(); let portal = Portal(store: store)
        let executor = NativeProfileCreationExecutor(store: store, portal: portal, clock: { Self.now })
        do { _ = try await executor.approve(owner: Self.owner(), contextID: UUID(), request: Self.request()); XCTFail("Real CMS verifier required") }
        catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsVerificationUnavailable) }
        do { _ = try await executor.reconcile(owner: Self.owner(), contextID: UUID(), request: Self.request(), authorityExpiresAt: Self.now.addingTimeInterval(120), checkCurrent: {}); XCTFail("No I/O without verifier") }
        catch { XCTAssertEqual(error as? NativeProfileValidationError, .cmsVerificationUnavailable) }
        XCTAssertEqual(store.lock.withLock { $0.reads }, 0)
        let values = await portal.values(); XCTAssertEqual(values.0, 0); XCTAssertEqual(values.1, 0)
    }

    func testIntentPrecedesCreateAndOnlyAuthenticatedEnvelopeIsRetained() async throws {
        let store = Store(); let portal = Portal(store: store)
        let executor = NativeProfileCreationExecutor(store: store, portal: portal, validator: try Self.validator(), clock: { Self.now })
        let owner = try Self.owner(); let request = try Self.request(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, request: request)
        let result = try await executor.execute(owner: owner, contextID: context, request: request, approval: grant, authorityExpiresAt: Self.now.addingTimeInterval(120), checkCurrent: {})
        XCTAssertEqual(result.profile.encodedCMS, Self.cms)
        XCTAssertEqual(result.profile.cmsSHA256, NativeSigningIdentityOwner.hash(Self.cms))
        XCTAssertEqual(store.lock.withLock { $0.row?.phase }, .recorded)
        let values = await portal.values(); XCTAssertEqual(values.0, 1); XCTAssertTrue(values.2)
    }

    func testFailedIntentWritePreventsCreation() async throws {
        let store = Store(); store.lock.withLock { $0.failInsert = true }; let portal = Portal(store: store)
        let executor = NativeProfileCreationExecutor(store: store, portal: portal, validator: try Self.validator(), clock: { Self.now })
        let owner = try Self.owner(); let request = try Self.request(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, request: request)
        do { _ = try await executor.execute(owner: owner, contextID: context, request: request, approval: grant, authorityExpiresAt: Self.now.addingTimeInterval(120), checkCurrent: {}); XCTFail("Must persist first") }
        catch { XCTAssertEqual(error as? NativeProfileCreationError, .storageUnavailable) }
        let values = await portal.values(); XCTAssertEqual(values.0, 0)
    }

    func testTimeoutRecoversWithoutAnotherCreate() async throws {
        let store = Store(); let portal = Portal(store: store, timeout: true)
        let validator = try Self.validator()
        let executor = NativeProfileCreationExecutor(store: store, portal: portal, validator: validator, clock: { Self.now })
        let owner = try Self.owner(); let request = try Self.request(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, request: request)
        do { _ = try await executor.execute(owner: owner, contextID: context, request: request, approval: grant, authorityExpiresAt: Self.now.addingTimeInterval(120), checkCurrent: {}); XCTFail("Timeout") }
        catch { XCTAssertEqual(error as? NativeProfileCreationError, .requestFailed) }
        let restarted = NativeProfileCreationExecutor(store: store, portal: portal, validator: validator, clock: { Self.now })
        _ = try await restarted.reconcile(owner: owner, contextID: context, request: request, authorityExpiresAt: Self.now.addingTimeInterval(120), checkCurrent: {})
        let values = await portal.values(); XCTAssertEqual(values.0, 1)
    }

    func testMissingProfileNeverResetsUncertainIntent() async throws {
        let store = Store(); let portal = Portal(store: store); await portal.hide()
        let executor = NativeProfileCreationExecutor(store: store, portal: portal, validator: try Self.validator(), clock: { Self.now })
        let owner = try Self.owner(); let request = try Self.request(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, request: request)
        do { _ = try await executor.execute(owner: owner, contextID: context, request: request, approval: grant, authorityExpiresAt: Self.now.addingTimeInterval(120), checkCurrent: {}); XCTFail("Not observed") }
        catch { XCTAssertEqual(error as? NativeProfileCreationError, .reconciliationRequired) }
        do { _ = try await executor.approve(owner: owner, contextID: context, request: request); XCTFail("No reissue") }
        catch { XCTAssertEqual(error as? NativeProfileCreationError, .reconciliationRequired) }
        XCTAssertEqual(store.lock.withLock { $0.row?.phase }, .uncertain)
    }

    func testProfileConstraintFailureNeverCommitsIssuedProfile() async throws {
        let store = Store(); let portal = Portal(store: store)
        let executor = NativeProfileCreationExecutor(store: store, portal: portal, validator: try Self.validator(wrongTeam: true), clock: { Self.now })
        let owner = try Self.owner(); let request = try Self.request(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, request: request)
        do { _ = try await executor.execute(owner: owner, contextID: context, request: request, approval: grant, authorityExpiresAt: Self.now.addingTimeInterval(120), checkCurrent: {}); XCTFail("Wrong team") }
        catch { XCTAssertEqual(error as? NativeProfileValidationError, .contextMismatch) }
        XCTAssertEqual(store.lock.withLock { $0.row?.phase }, .uncertain)
    }

    func testLogicalHashPreventsCaseAndRemoteIDAliasBypassButApprovalIsExact() throws {
        let first = try Self.request(); let alias = try Self.request(bundle: "com.example.Fixture", appID: "APP2")
        XCTAssertEqual(first.digest, alias.digest)
        XCTAssertNotEqual(first.approvalDigest, alias.approvalDigest)
        XCTAssertEqual(first.description, "NativeProfileCreationRequest(redacted)")
    }

    func testRevokedApprovalCannotCreate() async throws {
        let store = Store(); let portal = Portal(store: store)
        let executor = NativeProfileCreationExecutor(store: store, portal: portal, validator: try Self.validator(), clock: { Self.now })
        let owner = try Self.owner(); let request = try Self.request(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, request: request)
        await executor.revoke()
        do { _ = try await executor.execute(owner: owner, contextID: context, request: request, approval: grant, authorityExpiresAt: Self.now.addingTimeInterval(120), checkCurrent: {}); XCTFail("Revoked") }
        catch { XCTAssertEqual(error as? NativeProfileCreationError, .approvalRequired) }
        let values = await portal.values(); XCTAssertEqual(values.0, 0)
    }

    func testCMSUUIDCannotBeSubstitutedAfterTransportMetadataCheck() async throws {
        let store = Store(); let portal = Portal(store: store); await portal.substituteListedUUID()
        let executor = NativeProfileCreationExecutor(store: store, portal: portal, validator: try Self.validator(), clock: { Self.now })
        let owner = try Self.owner(); let request = try Self.request(); let context = UUID()
        let grant = try await executor.approve(owner: owner, contextID: context, request: request)
        do { _ = try await executor.execute(owner: owner, contextID: context, request: request, approval: grant, authorityExpiresAt: Self.now.addingTimeInterval(120), checkCurrent: {}); XCTFail("CMS/list UUID binding") }
        catch { XCTAssertEqual(error as? NativeProfileCreationError, .inventoryRejected) }
        XCTAssertEqual(store.lock.withLock { $0.row?.phase }, .uncertain)
    }

    func testExistingUUIDSelectionCannotAuthorizeNewProfileCreation() async throws {
        let store = Store(); let portal = Portal(store: store)
        let executor = NativeProfileCreationExecutor(store: store, portal: portal, validator: try Self.validator(), clock: { Self.now })
        do { _ = try await executor.approve(owner: Self.owner(), contextID: UUID(), request: Self.request(expectedUUID: UUID())); XCTFail("Existing profile selection is recovery-only") }
        catch { XCTAssertEqual(error as? NativeProfileCreationError, .invalidRequest) }
        let values = await portal.values(); XCTAssertEqual(values.0, 0); XCTAssertEqual(values.1, 0)
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
        func delete(_ query: [String: Any]) -> OSStatus { XCTFail("No profile reset/delete path"); return errSecParam }
    }

    func testProfileKeychainIntentUsesDeviceOnlyAndConditionalForwardCommit() throws {
        let client = KeychainClient(); let store = NativeProfileCreationKeychainStore(client: client)
        let owner = try Self.owner(); let request = try Self.request()
        var row = NativeProfileCreationRecord(schema: 1, id: UUID(), ownerDigest: owner.digest, targetDigest: request.digest,
            createdAt: Self.now, phase: .uncertain, remoteIdentifierDigest: nil, profileUUID: nil, cmsSHA256: nil)
        try store.insertIntent(row, owner: owner, request: request)
        XCTAssertEqual(client.attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(client.attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(client.attributes[kSecAttrAccessGroup as String])
        let bytes = try XCTUnwrap(client.attributes[kSecValueData as String] as? Data)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains(Self.udid)); XCTAssertFalse(text.contains(Self.bundle))
        row.phase = .recorded; row.remoteIdentifierDigest = NativeSigningIdentityOwner.hash(Data("PROFILE1".utf8))
        row.profileUUID = UUID(); row.cmsSHA256 = NativeSigningIdentityOwner.hash(Self.cms)
        try store.recordObservation(row, owner: owner, request: request)
        XCTAssertEqual(client.lastQuery[kSecAttrLabel as String] as? String, "uncertain")
        XCTAssertEqual(client.lastQuery[kSecAttrGeneric as String] as? Data, Data(row.id.uuidString.utf8))
        XCTAssertEqual(try store.read(owner: owner, request: request), row)
        XCTAssertThrowsError(try store.recordObservation(row, owner: owner, request: request))
    }

    func testProfileKeychainCorruptionAndLockDoNotBecomeAbsence() throws {
        let client = KeychainClient(); let store = NativeProfileCreationKeychainStore(client: client)
        client.status = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.read(owner: Self.owner(), request: Self.request())) {
            XCTAssertEqual($0 as? NativeProfileCreationError, .storageUnavailable)
        }
        client.status = errSecSuccess; client.attributes[kSecValueData as String] = Data("{\"schema\":99}".utf8)
        XCTAssertThrowsError(try store.read(owner: Self.owner(), request: Self.request())) {
            XCTAssertEqual($0 as? NativeProfileCreationError, .invalidJournal)
        }
        client.status = errSecItemNotFound
        XCTAssertNil(try store.read(owner: Self.owner(), request: Self.request()))
    }

}
