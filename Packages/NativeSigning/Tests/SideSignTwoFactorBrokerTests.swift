import Foundation
import XCTest
import SideSign
@testable import NativeSigningLinkSmoke

final class SideSignTwoFactorBrokerTests: XCTestCase {
    func testOperationAndChallengeIDsRejectStaleAndDuplicateReplies() async throws {
        let operation = UUID()
        let broker = SideSignTwoFactorBroker(operation: operation)
        var events = await broker.challengeEvents().makeAsyncIterator()
        let task = Task { try await broker.request(.trustedDevice(error: nil)) }
        defer { task.cancel() }
        let event = await events.next()
        let challenge = try XCTUnwrap(event)
        let staleOperation = await broker.submit(.verificationCode("123456"), operation: UUID(), challengeID: challenge.id)
        let staleChallenge = await broker.submit(.verificationCode("123456"), operation: operation, challengeID: UUID())
        XCTAssertFalse(staleOperation)
        XCTAssertFalse(staleChallenge)
        let accepted = await broker.submit(.verificationCode("123456"), operation: operation, challengeID: challenge.id)
        XCTAssertTrue(accepted)
        let duplicate = await broker.submit(.verificationCode("123456"), operation: operation, challengeID: challenge.id)
        XCTAssertFalse(duplicate)
        guard case .verificationCode(let code) = try await task.value else { return XCTFail("Expected code") }
        XCTAssertEqual(code, "123456")
        await broker.cancel()
    }

    func testCancellationResumesSuspendedSDKAndClearsChallenge() async throws {
        let broker = SideSignTwoFactorBroker(operation: UUID())
        var events = await broker.challengeEvents().makeAsyncIterator()
        let task = Task { try await broker.request(.trustedDevice(error: nil)) }
        defer { task.cancel() }
        _ = await events.next()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must unblock the SDK")
        } catch { XCTAssertTrue(error is CancellationError) }
        let pending = await broker.pendingChallenge()
        XCTAssertNil(pending)
    }

    func testDeliveryChoicesAndASCIICodesAreValidatedWithoutConsumingChallenge() async throws {
        let operation = UUID()
        let broker = SideSignTwoFactorBroker(operation: operation)
        var events = await broker.challengeEvents().makeAsyncIterator()
        let phones = [TrustedPhoneNumber(id: "known", number: "***12")]
        let first = Task { try await broker.request(.selectDeliveryMethod(preferredMode: .sms, phoneNumbers: phones)) }
        defer { first.cancel() }
        let event = await events.next()
        let challenge = try XCTUnwrap(event)
        let earlyCode = await broker.submit(.verificationCode("123456"), operation: operation, challengeID: challenge.id)
        let unknownPhone = await broker.submit(.requestSMS(phoneID: "other"), operation: operation, challengeID: challenge.id)
        XCTAssertFalse(earlyCode)
        XCTAssertFalse(unknownPhone)
        let delivered = await broker.submit(.requestSMS(phoneID: "known"), operation: operation, challengeID: challenge.id)
        XCTAssertTrue(delivered)
        guard case .requestSMS(let phoneID) = try await first.value else { return XCTFail("Expected delivery") }
        XCTAssertEqual(phoneID, "known")
        let second = Task { try await broker.request(.sms(phoneNumbers: phones, activeID: "known", error: nil)) }
        defer { second.cancel() }
        let next = await events.next()
        let codeChallenge = try XCTUnwrap(next)
        for code in ["12345", "１２３４５６", "123 56"] {
            let result = await broker.submit(.verificationCode(code), operation: operation, challengeID: codeChallenge.id)
            XCTAssertFalse(result)
        }
        let accepted = await broker.submit(.verificationCode("123456"), operation: operation, challengeID: codeChallenge.id)
        XCTAssertTrue(accepted)
        _ = try await second.value
        await broker.cancel()
    }

    func testRawRetryErrorIsRemovedAndUserCancellationIsTerminal() async throws {
        let operation = UUID()
        let broker = SideSignTwoFactorBroker(operation: operation)
        var events = await broker.challengeEvents().makeAsyncIterator()
        let task = Task { try await broker.request(.trustedDevice(error: "RAW-SECRET-PAYLOAD")) }
        defer { task.cancel() }
        let event = await events.next()
        let challenge = try XCTUnwrap(event)
        XCTAssertTrue(challenge.isRetry)
        XCTAssertNil(challenge.request.error)
        let accepted = await broker.submit(.cancel, operation: operation, challengeID: challenge.id)
        XCTAssertTrue(accepted)
        guard case .cancel = try await task.value else { return XCTFail("Expected cancellation") }
        do {
            _ = try await broker.request(.trustedDevice(error: nil))
            XCTFail("A cancelled broker cannot restart")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testConcurrentChallengeCannotOverwritePendingContinuation() async throws {
        let broker = SideSignTwoFactorBroker(operation: UUID())
        var events = await broker.challengeEvents().makeAsyncIterator()
        let task = Task { try await broker.request(.trustedDevice(error: nil)) }
        defer { task.cancel() }
        _ = await events.next()
        do {
            _ = try await broker.request(.trustedDevice(error: nil))
            XCTFail("Only one pending SDK challenge")
        } catch { XCTAssertEqual(error as? SideSignTwoFactorBrokerError, .challengeAlreadyPending) }
        await broker.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testReplacementObserverReceivesPendingChallenge() async throws {
        let broker = SideSignTwoFactorBroker(operation: UUID())
        var firstEvents = await broker.challengeEvents().makeAsyncIterator()
        let task = Task { try await broker.request(.trustedDevice(error: nil)) }
        defer { task.cancel() }
        let first = await firstEvents.next()
        var replacement = await broker.challengeEvents().makeAsyncIterator()
        let replayed = await replacement.next()
        XCTAssertEqual(first, replayed)
        let ended = await firstEvents.next()
        XCTAssertNil(ended)
        await broker.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
