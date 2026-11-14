import XCTest
import UIKit
import NimbleExtensions
@testable import VexSign

/// Launching an installed app depends on LaunchServices private API that any iOS release can
/// filter out. These tests pin the two things that keep that dependency survivable: the request
/// fails *loudly* instead of silently, and a missing selector cannot terminate the app.
final class PrivateLaunchSurfaceTests: XCTestCase {
    func testLaunchingWithAnEmptyIdentifierReportsFailureInsteadOfDispatching() {
        // The empty-identifier guard runs before any private class is resolved, so this is a
        // deterministic contract rather than an observation about the current iOS build.
        XCTAssertFalse(UIApplication.openApp(with: ""),
                       "An empty identifier cannot name an app; it must report failure")
    }

    func testLaunchingAnUnknownAppCannotTerminateTheProcess() {
        // Reaching the end of this method *is* the assertion, so there is deliberately no
        // expectation about the returned value: whether the launch was dispatched depends on the
        // iOS build the suite runs on. What must hold on every build is that the call returns at
        // all. `perform(_:)` against a selector the workspace does not implement raises
        // `doesNotRecognizeSelector:` and terminates the process, which would be reported as a
        // crashed test runner rather than a failure — the regression this test exists to catch.
        _ = UIApplication.openApp(with: "com.vexsign.tests.no-such-app")
    }
}
