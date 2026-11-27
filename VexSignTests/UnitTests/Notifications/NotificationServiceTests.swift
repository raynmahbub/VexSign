//
//  NotificationServiceTests.swift
//  VexSign
//
//  Deterministic tests for authorization, preference gating, stable IDs,
//  dedupe, categories, actions and payload hygiene. No real notification is
//  posted: the centre is a recorder supplied to the service.
//

import Foundation
import XCTest
import UserNotifications
@testable import VexSign

final class NotificationServiceTests: XCTestCase {
    private final class FakeCenter: NotificationCenterServicing {
        var status: UNAuthorizationStatus = .authorized
        var requests: [UNNotificationRequest] = []
        var delivered: [UNNotification] = []
        var categories: Set<UNNotificationCategory> = []
        var shouldFail = false

        func vxs_authorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
            completion(status)
        }

        func vxs_requestAuthorization(_ options: UNAuthorizationOptions,
                                      completion: @escaping (Bool, Error?) -> Void) {
            status = .authorized
            completion(true, nil)
        }

        func vxs_add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
            if shouldFail {
                completion(NSError(domain: "test", code: 1))
                return
            }
            // A repeated stable identifier replaces the previous request, as
            // UNUserNotificationCenter does.
            requests.removeAll { $0.identifier == request.identifier }
            requests.append(request)
            completion(nil)
        }

        func vxs_removePending(_ identifiers: [String]) {
            requests.removeAll { identifiers.contains($0.identifier) }
        }

        func vxs_removeDelivered(_ identifiers: [String]) {
            delivered.removeAll { identifiers.contains($0.request.identifier) }
        }

        func vxs_pendingRequests(_ completion: @escaping ([UNNotificationRequest]) -> Void) {
            completion(requests)
        }

        func vxs_deliveredNotifications(_ completion: @escaping ([UNNotification]) -> Void) {
            completion(delivered)
        }

        func vxs_setCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }
        func vxs_setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {}
    }

    private func makeService() -> (VexSignNotificationService, FakeCenter, UserDefaults) {
        let suite = "VexSignTests.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let center = FakeCenter()
        let service = VexSignNotificationService(center: center, defaults: defaults, clock: Date.init)
        service.configure()
        return (service, center, defaults)
    }

    private func note(_ identifier: String = "vexsign.test.1",
                      topic: NotificationTopic = .downloads) -> VexSignNotification {
        VexSignNotification(
            identifier: identifier,
            topic: topic,
            title: "Done",
            body: "The operation finished.",
            category: .task,
            details: [NotificationPayloadKey.route.rawValue: "tasks"]
        )
    }

    @MainActor
    func testDeniedAuthorizationBlocksPosting() async {
        let (service, center, _) = makeService()
        center.status = .denied
        service.refreshAuthorizationStatus()
        await service.currentAuthorization()
        let posted = await service.post(note())
        XCTAssertFalse(posted)
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertTrue(VexSignNotificationService.allowsDelivery(.provisional))
        XCTAssertFalse(VexSignNotificationService.allowsDelivery(.notDetermined))
    }

    @MainActor
    func testPreferenceToggleBlocksOnlyItsTopic() async {
        let (service, center, _) = makeService()
        service.preferences.set(.downloads, enabled: false)
        XCTAssertFalse(await service.post(note()))
        XCTAssertTrue(await service.post(note(topic: .appUpdates)))
        XCTAssertEqual(center.requests.count, 1)
    }

    @MainActor
    func testDedupeKeyPreventsRepeatedBannerButDifferentContentPasses() async {
        let (service, center, _) = makeService()
        XCTAssertTrue(await service.post(note(), dedupeContentKey: "outcome"))
        XCTAssertFalse(await service.post(note(), dedupeContentKey: "outcome"))
        XCTAssertTrue(await service.post(note(), dedupeContentKey: "different-outcome"))
        XCTAssertEqual(center.requests.count, 1, "the stable identifier replaces its own request")
        XCTAssertEqual(service.history.entries.count, 1)
    }

    @MainActor
    func testCategoriesIncludeReviewAndDismissActions() {
        let (service, center, _) = makeService()
        XCTAssertEqual(center.categories.count, VexSignNotificationCategory.allCases.count)
        let expiry = center.categories.first {
            $0.identifier == VexSignNotificationCategory.expiry.identifier
        }
        XCTAssertNotNil(expiry)
        XCTAssertEqual(expiry?.actions.map(\.identifier), [
            NotificationAction.review.rawValue, NotificationAction.dismiss.rawValue
        ])
        _ = service
    }

    @MainActor
    func testPayloadDropsSecretsAndUnknownKeys() {
        let sanitized = VexSignNotificationService.sanitized([
            "password": "hunter2",
            NotificationPayloadKey.route.rawValue: "tasks",
            NotificationPayloadKey.version.rawValue: "abc123@example.com",
            NotificationPayloadKey.bundleID.rawValue: "com.example.app",
            "token": "secret"
        ])
        XCTAssertEqual(sanitized, [
            NotificationPayloadKey.route.rawValue: "tasks",
            NotificationPayloadKey.bundleID.rawValue: "com.example.app"
        ])
        XCTAssertTrue(VexSignNotificationService.looksSensitive("123e4567-e89b-12d3-a456-426614174000"))
    }

    @MainActor
    func testActionRoutingNeverInstalls() {
        XCTAssertEqual(NotificationRoute.from(details: [:], actionIdentifier: NotificationAction.dismiss.rawValue), .none)
        XCTAssertEqual(NotificationRoute.from(details: [:], actionIdentifier: NotificationAction.reviewUpdates.rawValue), .updates)
        XCTAssertEqual(
            NotificationRoute.from(
                details: [NotificationPayloadKey.route.rawValue: "certificates"],
                actionIdentifier: NotificationAction.review.rawValue
            ),
            .certificates
        )
    }

    @MainActor
    func testCancelPrefixRemovesPendingAndDelivered() async {
        let (service, center, _) = makeService()
        await service.post(note("com.vexsign.expiry.certificate.abc.7"))
        await service.post(note("com.vexsign.other"))
        service.cancel(prefix: "com.vexsign.expiry.")
        XCTAssertEqual(center.requests.map(\.identifier), ["com.vexsign.other"])
    }
}
