import Foundation
import Security
import LocalAuthentication
import XCTest
@testable import VexSign

final class AppleAccountCredentialStoreTests: XCTestCase {
    /// Local synchronous test double; deliberately not marked unchecked Sendable.
    private final class Client: AppleAccountKeychainClient {
        var requests: [[String: Any]] = []
        var items: [String: Data] = [:]
        var forcedStatus: OSStatus?
        var corruptRead = false

        private func key(_ query: [String: Any]) -> String {
            (query[kSecAttrService as String] as? String ?? "") + ":" + (query[kSecAttrAccount as String] as? String ?? "")
        }
        func add(_ attributes: [String: Any]) -> OSStatus {
            requests.append(attributes)
            if let forcedStatus { return forcedStatus }
            let id = key(attributes)
            if items[id] != nil { return errSecDuplicateItem }
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            items[id] = data
            return errSecSuccess
        }
        func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
            requests.append(query)
            if let forcedStatus { return (forcedStatus, nil) }
            if corruptRead { return (errSecSuccess, nil) }
            guard let data = items[key(query)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
        func delete(_ query: [String: Any]) -> OSStatus {
            requests.append(query)
            if let forcedStatus { return forcedStatus }
            return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func testRecordsAreDeviceOnlyUnlockedNonSynchronizingAndNotShared() throws {
        let client = Client()
        let store = AppleAccountCredentialStore(client: client)
        let reference = UUID()
        try store.insertSession(Data("opaque-session-fixture".utf8), reference: reference)
        let query = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(query[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.vexsign.apple-account.sessions.v1")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "session." + reference.uuidString)
        XCTAssertNil(query[kSecAttrAccessGroup as String])
        XCTAssertNil(query[kSecAttrLabel as String])
    }

    func testSessionRoundTripAndExactIdempotentDeletion() throws {
        let client = Client()
        let store = AppleAccountCredentialStore(client: client)
        let first = try store.insertSession(Data("first-fixture".utf8))
        let second = try store.insertSession(Data("second-fixture".utf8))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try store.readSession(reference: first), Data("first-fixture".utf8))
        try store.deleteSession(reference: first)
        try store.deleteSession(reference: first)
        XCTAssertNil(try store.readSession(reference: first))
        XCTAssertEqual(try store.readSession(reference: second), Data("second-fixture".utf8))
        for query in client.requests {
            XCTAssertNotNil(query[kSecAttrAccount as String], "No service-wide delete/query")
        }
    }

    func testDuplicateReferenceCannotOverwriteAcceptedSession() throws {
        let client = Client()
        let store = AppleAccountCredentialStore(client: client)
        let id = try store.insertSession(Data("accepted-fixture".utf8))
        XCTAssertThrowsError(try store.insertSession(Data("late-fixture".utf8), reference: id)) {
            XCTAssertEqual($0 as? AppleAccountCredentialStoreError, .keychainStatus(errSecDuplicateItem))
        }
        XCTAssertEqual(try store.readSession(reference: id), Data("accepted-fixture".utf8))
    }

    func testLockedAndUnauthorizedStorageAreErrorsNotMissingSessions() {
        let client = Client()
        let store = AppleAccountCredentialStore(client: client)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement] {
            client.forcedStatus = status
            XCTAssertThrowsError(try store.readSession(reference: UUID())) {
                XCTAssertEqual($0 as? AppleAccountCredentialStoreError, .keychainStatus(status))
            }
        }
    }

    func testReadNeverRequestsInteractiveAuthentication() throws {
        let client = Client()
        let store = AppleAccountCredentialStore(client: client)
        XCTAssertNil(try store.readSession(reference: UUID()))
        let query = try XCTUnwrap(client.requests.last)
        XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

    func testCorruptReplyIsNotSilentlyTreatedAsSignedOut() {
        let client = Client()
        client.corruptRead = true
        let store = AppleAccountCredentialStore(client: client)
        XCTAssertThrowsError(try store.readSession(reference: UUID())) {
            XCTAssertEqual($0 as? AppleAccountCredentialStoreError, .invalidStoredSession)
        }
    }

    func testEmptyAndOversizedDataAreRejectedBeforeKeychainAccess() {
        let client = Client()
        let store = AppleAccountCredentialStore(client: client)
        for data in [Data(), Data(repeating: 0, count: 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try store.insertSession(data)) {
                XCTAssertEqual($0 as? AppleAccountCredentialStoreError, .invalidSessionSize)
            }
        }
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testWriteAndDeletionFailuresArePropagated() {
        let client = Client()
        client.forcedStatus = errSecNotAvailable
        let store = AppleAccountCredentialStore(client: client)
        XCTAssertThrowsError(try store.insertSession(Data("fixture".utf8))) {
            XCTAssertEqual($0 as? AppleAccountCredentialStoreError, .keychainStatus(errSecNotAvailable))
        }
        XCTAssertThrowsError(try store.deleteSession(reference: UUID())) {
            XCTAssertEqual($0 as? AppleAccountCredentialStoreError, .keychainStatus(errSecNotAvailable))
        }
    }
}
