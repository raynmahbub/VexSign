import XCTest
@testable import VexSign

final class LibraryGridSwipePolicyTests: XCTestCase {
    func testLeftAndRightSwipesRevealAndClose() {
        XCTAssertTrue(LibraryGridSwipePolicy.isOpenAfterSwipe(horizontal: -60, vertical: 5, currentlyOpen: false))
        XCTAssertFalse(LibraryGridSwipePolicy.isOpenAfterSwipe(horizontal: 60, vertical: 5, currentlyOpen: true))
    }

    func testRevealingAnotherRowReplacesTheOneOpenIdentity() {
        let next = LibraryGridSwipePolicy.revealedRow(after: -70, vertical: 3, row: "imported:second", current: "signed:first")
        XCTAssertEqual(next, "imported:second")
        XCTAssertNil(LibraryGridSwipePolicy.revealedRow(after: 70, vertical: 3, row: "imported:second", current: next))
    }

    func testClosingAnUnrelatedRowDoesNotLoseTheOpenRowsIdentity() {
        XCTAssertEqual(LibraryGridSwipePolicy.revealedRow(after: 70, vertical: 0, row: "imported:second", current: "signed:first"), "signed:first")
        XCTAssertEqual(LibraryGridSwipePolicy.revealedRow(after: -10, vertical: 100, row: "imported:second", current: "signed:first"), "signed:first")
    }

    func testAFullLengthSwipeStillOnlyRevealsAnAction() {
        XCTAssertEqual(LibraryGridSwipePolicy.revealedRow(after: -10_000, vertical: 0, row: "signed:copy", current: nil), "signed:copy")
        XCTAssertNil(LibraryGridSwipePolicy.revealedRow(after: 10_000, vertical: 0, row: "signed:copy", current: "signed:copy"))
        // The policy has no delete callback. Confirmation belongs to the row.
    }

    func testDynamicTypeActionWidthStaysCompactWithoutShrinkingTheTouchTarget() {
        XCTAssertEqual(LibraryGridSwipePolicy.actionWidth(scaled: 82), 82)
        XCTAssertEqual(LibraryGridSwipePolicy.actionWidth(scaled: 1), 72)
        XCTAssertEqual(LibraryGridSwipePolicy.actionWidth(scaled: 240), 136)
        XCTAssertEqual(LibraryGridSwipePolicy.actionWidth(scaled: .infinity), 82)
        XCTAssertEqual(LibraryGridSwipePolicy.actionWidth(scaled: .nan), 82)
    }

    func testSmallOrMostlyVerticalGesturesDoNotChangeState() {
        for open in [false, true] {
            XCTAssertEqual(LibraryGridSwipePolicy.isOpenAfterSwipe(horizontal: -44, vertical: 0, currentlyOpen: open), open)
            XCTAssertEqual(LibraryGridSwipePolicy.isOpenAfterSwipe(horizontal: -60, vertical: 60, currentlyOpen: open), open)
            XCTAssertEqual(LibraryGridSwipePolicy.isOpenAfterSwipe(horizontal: 0, vertical: 100, currentlyOpen: open), open)
        }
    }
}
