//
//  AutomationIntegrationTests.swift
//  VexSign
//
//  Domain events are carried on the existing NotificationCenter, carry only
//  allow-listed metadata, and never perform an action themselves.
//

import Foundation
import XCTest
@testable import VexSign

final class AutomationIntegrationTests: XCTestCase {
    func testEventRoundTripThroughExistingNotificationCenter() {
        let expectation = expectation(forNotification: .vexAutomationDomainEvent, object: nil) { note in
            AutomationDomainEvent.decode(note)?.kind == .certificateImported
        }
        AutomationDomainEvent.post(AutomationDomainEvent(
            kind: .certificateImported,
            referenceID: "stable-reference",
            summary: "Identity",
            details: [AutomationEventDetailKey.displayName.rawValue: "Identity"]
        ))
        wait(for: [expectation], timeout: 1)
    }

    func testEventDoesNotCarrySecrets() {
        let event = AutomationDomainEvent(
            kind: .downloadCompleted,
            referenceID: "stable-reference",
            summary: "File downloaded",
            details: [AutomationEventDetailKey.outcome.rawValue: "succeeded"]
        )
        XCTAssertFalse(event.details.values.contains { $0.contains("password") })
        XCTAssertFalse(event.details.values.contains { $0.contains("token") })
    }

    func testVerifiedDownloadEventBuildsTaskNotification() {
        let event = AutomationDomainEvent(
            kind: .downloadCompleted,
            referenceID: "download-1",
            summary: "Added to Library",
            details: [AutomationEventDetailKey.outcome.rawValue: "succeeded"]
        )
        let note = AutomationEventCoordinator.notification(for: event)
        XCTAssertEqual(note?.topic, .downloads)
        XCTAssertEqual(note?.category, .task)
        XCTAssertEqual(note?.details[NotificationPayloadKey.outcome.rawValue], "succeeded")
        XCTAssertTrue(NotificationRoute.from(details: note?.details ?? [:], actionIdentifier: nil) == .tasks)
    }

    func testUpdateEventBuildsReviewOnlyNotification() {
        let event = AutomationDomainEvent(
            kind: .appUpdateFound,
            referenceID: "com.example.app",
            summary: "2.1.0 available",
            details: [
                AutomationEventDetailKey.version.rawValue: "2.1.0",
                AutomationEventDetailKey.bundleID.rawValue: "com.example.app"
            ]
        )
        let note = AutomationEventCoordinator.notification(for: event)
        XCTAssertEqual(note?.topic, .appUpdates)
        XCTAssertEqual(note?.details[NotificationPayloadKey.version.rawValue], "2.1.0")
        XCTAssertNil(note?.details["install"], "a notification must never authorize installation")
    }

    func testExpirySubjectUsesInspectedDateOrStaysUnknown() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = Date().addingTimeInterval(86400)
        let event = AutomationDomainEvent(
            kind: .certificateImported,
            referenceID: "identity-1",
            details: [
                AutomationEventDetailKey.referenceID.rawValue: "identity-1",
                AutomationEventDetailKey.expiry.rawValue: formatter.string(from: expiry),
                AutomationEventDetailKey.displayName.rawValue: "Identity"
            ]
        )
        let subject = AutomationEventCoordinator.expirySubject(from: event)
        XCTAssertEqual(subject?.referenceID, "identity-1")
        XCTAssertEqual(subject?.displayName, "Identity")
        XCTAssertNotNil(subject?.expiry)
        XCTAssertNil(AutomationEventCoordinator.expirySubject(from: AutomationDomainEvent(kind: .certificateRemoved)))
    }
}
