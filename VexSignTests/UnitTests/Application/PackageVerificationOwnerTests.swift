import XCTest
@testable import VexSign

final class PackageVerificationOwnerTests: XCTestCase {
    func testOnlyOneWorkerAndHandoff() throws {
        let owner = PackageVerificationOwner()
        let token = try XCTUnwrap(owner.begin())
        XCTAssertNil(owner.begin())
        XCTAssertThrowsError(try owner.check(UUID()))
        XCTAssertFalse(owner.finish(UUID(), requiresDecision: false))
        try owner.check(token)
        XCTAssertTrue(owner.finish(token, requiresDecision: false))
        XCTAssertFalse(owner.finish(token, requiresDecision: false))
        XCTAssertNil(owner.begin())
        XCTAssertFalse(owner.acceptOverride())
    }

    func testCancelledLateVerdictCannotImport() throws {
        let owner = PackageVerificationOwner()
        let token = try XCTUnwrap(owner.begin())
        owner.cancel()
        XCTAssertThrowsError(try owner.check(token))
        XCTAssertFalse(owner.finish(token, requiresDecision: false))
        XCTAssertFalse(owner.acceptOverride())
        XCTAssertNil(owner.begin())
    }

    func testMismatchNeedsExactlyOneExplicitOverride() throws {
        let owner = PackageVerificationOwner()
        let token = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.finish(token, requiresDecision: true))
        XCTAssertNil(owner.begin())
        XCTAssertTrue(owner.acceptOverride())
        XCTAssertFalse(owner.acceptOverride())
    }

    func testDeletingMismatchClosesOverride() throws {
        let owner = PackageVerificationOwner()
        let token = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.finish(token, requiresDecision: true))
        owner.cancel()
        XCTAssertFalse(owner.acceptOverride())
    }
}
