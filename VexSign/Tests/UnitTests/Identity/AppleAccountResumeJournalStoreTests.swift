import Foundation
import XCTest
import Security
import LocalAuthentication
@testable import VexSign

final class AppleAccountResumeJournalStoreTests: XCTestCase {
    private final class Client: AppleAccountJournalKeychainClient {
        var data: Data?
        var copyStatus: OSStatus?
        var updateStatus: OSStatus?
        var addStatus: OSStatus = errSecSuccess
        var adds: [[String: Any]] = []
        var queries: [[String: Any]] = []
        var updates: [([String: Any], [String: Any])] = []
        func add(_ attributes: [String: Any]) -> OSStatus {
            adds.append(attributes)
            if addStatus == errSecSuccess { data = attributes[kSecValueData as String] as? Data }
            return addStatus
        }
        func copy(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
            queries.append(query)
            return (copyStatus ?? (data == nil ? errSecItemNotFound : errSecSuccess), data)
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            updates.append((query, attributes))
            if let status = updateStatus { return status }
            guard data != nil else { return errSecItemNotFound }
            data = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
        func delete(_ query: [String: Any]) -> OSStatus {
            XCTFail("The journal store must never purge session/journal items")
            return errSecParam
        }
    }

    func testDedicatedDeviceOnlyPolicyAndAtomicReplacement() throws {
        let client = Client()
        let store = AppleAccountResumeJournalStore(client: client)
        let empty = AppleAccountResumeJournal()
        try store.writeJournal(empty)
        let inserted = try XCTUnwrap(client.adds.first)
        XCTAssertEqual(inserted[kSecAttrService as String] as? String, AppleAccountResumeJournalStore<Client>.service)
        XCTAssertNotEqual(AppleAccountResumeJournalStore<Client>.service, AppleAccountCredentialStore<Client>.service)
        XCTAssertEqual(inserted[kSecAttrAccount as String] as? String, "primary")
        XCTAssertEqual(inserted[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(inserted[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNil(inserted[kSecAttrAccessGroup as String])
        var selected = empty
        selected.selectedReference = UUID()
        try store.writeJournal(selected)
        XCTAssertEqual(client.adds.count, 1)
        XCTAssertEqual(try store.readJournal(), selected)
        let query = try XCTUnwrap(client.queries.last)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertTrue((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
    }

    func testOnlyNotFoundMeansMissingAndLockedReadPropagates() throws {
        let client = Client()
        let store = AppleAccountResumeJournalStore(client: client)
        XCTAssertNil(try store.readJournal())
        client.copyStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.readJournal()) {
            XCTAssertEqual($0 as? AppleAccountCredentialStoreError, .keychainStatus(errSecInteractionNotAllowed))
        }
    }

    func testCorruptEmptyOversizedAndUnsupportedRepliesFailClosed() throws {
        let client = Client()
        let store = AppleAccountResumeJournalStore(client: client)
        client.copyStatus = errSecSuccess
        let invalidPayloads: [Data?] = [nil, Data(), Data("invalid".utf8), Data(repeating: 0, count: 16 * 1024 + 1)]
        for data in invalidPayloads {
            client.data = data
            XCTAssertThrowsError(try store.readJournal()) {
                XCTAssertEqual($0 as? AppleAccountSessionRepositoryError, .invalidJournal)
            }
        }
        var future = AppleAccountResumeJournal()
        future.schema = 2
        client.data = try JSONEncoder().encode(future)
        XCTAssertThrowsError(try store.readJournal()) {
            XCTAssertEqual($0 as? AppleAccountSessionRepositoryError, .unsupportedJournalVersion)
        }
    }

    func testUpdateFailureNeverFallsBackToAdd() throws {
        let client = Client()
        client.updateStatus = errSecAuthFailed
        let store = AppleAccountResumeJournalStore(client: client)
        XCTAssertThrowsError(try store.writeJournal(AppleAccountResumeJournal())) {
            XCTAssertEqual($0 as? AppleAccountCredentialStoreError, .keychainStatus(errSecAuthFailed))
        }
        XCTAssertTrue(client.adds.isEmpty)
    }

    func testConcurrentDuplicateAddPropagatesInsteadOfOverwriting() throws {
        let client = Client()
        client.addStatus = errSecDuplicateItem
        let store = AppleAccountResumeJournalStore(client: client)
        XCTAssertThrowsError(try store.writeJournal(AppleAccountResumeJournal())) {
            XCTAssertEqual($0 as? AppleAccountCredentialStoreError, .keychainStatus(errSecDuplicateItem))
        }
        XCTAssertEqual(client.adds.count, 1)
        XCTAssertEqual(client.updates.count, 1)
    }

    func testInvalidOwnershipCannotBeWritten() throws {
        let client = Client()
        let store = AppleAccountResumeJournalStore(client: client)
        let reference = UUID()
        var journal = AppleAccountResumeJournal()
        journal.selectedReference = reference
        journal.pendingDeletions = [reference]
        XCTAssertThrowsError(try store.writeJournal(journal)) {
            XCTAssertEqual($0 as? AppleAccountSessionRepositoryError, .invalidJournal)
        }
        XCTAssertTrue(client.updates.isEmpty)
        XCTAssertTrue(client.adds.isEmpty)
    }
}
