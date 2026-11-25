import XCTest
@testable import VexSign

final class ProfileExpiryWindowTests: XCTestCase {
    func testRollingBoundariesAndSaturation() {
        let now = Date(timeIntervalSince1970: 0)
        let day: Double = 86_400
        let cases: [(Double, ProfileExpiryWindow.Milestone, Double)] = [
            (-1, .expired, 0), (0, .expired, 0), (1, .finalDay, 1 / (7 * day)),
            (day, .days(1), 1.0 / 7), (7 * day - 1, .days(6), 1 - 1 / (7 * day)),
            (7 * day, .weekOrMore, 1), (365 * day, .weekOrMore, 1)
        ]
        for (seconds, milestone, fraction) in cases {
            let window = ProfileExpiryWindow(expiration: now.addingTimeInterval(seconds), now: now)
            XCTAssertEqual(window.milestone, milestone)
            XCTAssertEqual(window.fraction, fraction, accuracy: 1e-10)
        }
    }
}
