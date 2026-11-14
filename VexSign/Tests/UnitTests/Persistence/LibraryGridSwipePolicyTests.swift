import XCTest
@testable import VexSign

final class LibraryGridSwipePolicyTests: XCTestCase {
    func testLeftAndRightSwipesRevealAndClose() {
        XCTAssertTrue(LibraryGridSwipePolicy.isOpenAfterSwipe(horizontal: -60, vertical: 5, currentlyOpen: false))
        XCTAssertFalse(LibraryGridSwipePolicy.isOpenAfterSwipe(horizontal: 60, vertical: 5, currentlyOpen: true))
    }

    func testSmallOrMostlyVerticalGesturesDoNotChangeState() {
        for open in [false, true] {
            XCTAssertEqual(LibraryGridSwipePolicy.isOpenAfterSwipe(horizontal: -44, vertical: 0, currentlyOpen: open), open)
            XCTAssertEqual(LibraryGridSwipePolicy.isOpenAfterSwipe(horizontal: -60, vertical: 60, currentlyOpen: open), open)
            XCTAssertEqual(LibraryGridSwipePolicy.isOpenAfterSwipe(horizontal: 0, vertical: 100, currentlyOpen: open), open)
        }
    }
}
