import XCTest
@testable import VexSign

final class AccountRefreshAutomationTests: XCTestCase {
    func testDisabledAutomationNeverReminds() {
        for due in [true, false] {
            for ready in [true, false] {
                let decision = AccountRefreshAutomationPolicy.decide(
                    isEnabled: false, hasDueRefresh: due,
                    sessionReady: ready, fromBackground: true
                )
                XCTAssertEqual(decision, .skip)
            }
        }
    }

    func testNoDueRefreshIsSilent() {
        XCTAssertEqual(
            AccountRefreshAutomationPolicy.decide(
                isEnabled: true, hasDueRefresh: false,
                sessionReady: true, fromBackground: true
            ),
            .skip
        )
    }

    func testBackgroundRemindsForAuthenticationOrApprovalWithoutChangingAccount() {
        XCTAssertEqual(
            AccountRefreshAutomationPolicy.decide(
                isEnabled: true, hasDueRefresh: true,
                sessionReady: false, fromBackground: true
            ),
            .remind(.sessionNeedsAuthentication)
        )
        XCTAssertEqual(
            AccountRefreshAutomationPolicy.decide(
                isEnabled: true, hasDueRefresh: true,
                sessionReady: true, fromBackground: true
            ),
            .remind(.approvalRequired)
        )
    }

    func testShortcutOpensReviewInsteadOfPerformingAccountWork() {
        XCTAssertEqual(
            AccountRefreshAutomationPolicy.decide(
                isEnabled: true, hasDueRefresh: true,
                sessionReady: false, fromBackground: false
            ),
            .openReview
        )
    }
}
