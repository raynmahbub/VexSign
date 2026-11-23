//
//  SelfReplacementPolicyTests.swift
//  VexSignTests
//
//  "Reinstall" used to be a button that could not work in any configuration: every remote route
//  was refused, correctly, and nothing else existed. The route that does work needs no remote
//  party — sign the release here, serve it here, let iOS replace the bundle — and its conditions
//  are one pure question. These tests are that question.
//

import Foundation
import XCTest
@testable import VexSign

final class SelfReplacementPolicyTests: XCTestCase {
    private func verdict(
        identifier: String? = "com.example.app",
        version: String? = "2.0",
        signed: Bool = true,
        running: String? = "com.example.app",
        runningVersion: String = "1.0"
    ) -> SelfReplacementBlocker? {
        SelfReplacementPolicy.verdict(
            candidate: .init(identifier: identifier, version: version, isSigned: signed),
            runningIdentifier: running,
            runningVersion: runningVersion
        )
    }

    // MARK: - The case that may install

    func testSignedNewerCopyOfThisAppMayReplaceIt() {
        XCTAssertNil(verdict())
        XCTAssertNil(verdict(version: "1.0.1"))
        XCTAssertNil(verdict(version: "1.10"), "components compare numerically, not as text")
    }

    // MARK: - Refusals

    func testAnotherAppIsNeverAnInPlaceUpdate() {
        XCTAssertEqual(verdict(identifier: "com.example.other"), .differentApp)
        XCTAssertEqual(verdict(identifier: nil), .differentApp)
        XCTAssertEqual(verdict(running: nil), .differentApp)
        XCTAssertEqual(verdict(running: ""), .differentApp)
    }

    func testAnUnsignedCopyIsRefusedBeforeItsVersionIsConsidered() {
        XCTAssertEqual(verdict(signed: false), .notSigned)
        XCTAssertEqual(verdict(version: nil, signed: false), .notSigned)
    }

    func testSameOlderAndUnknownVersionsAreRefused() {
        for version in ["1.0", "0.9", "1.0-beta", nil, ""] {
            XCTAssertEqual(verdict(version: version), .notNewer, "\(version ?? "<nil>") must not install")
        }
    }

    func testAPrereleaseOfTheSameVersionDoesNotCountAsNewer() {
        // The update check already orders `1.0-beta` below `1.0`; installing must agree with it.
        XCTAssertEqual(verdict(version: "1.0-beta", runningVersion: "1.0"), .notNewer)
    }

    // MARK: - Selection

    func testTheFirstUsableCopyWinsAndOrderIsTheCallers() {
        let copied = [
            SelfReplacementCandidate(identifier: "com.example.app", version: "1.0", isSigned: true),
            SelfReplacementCandidate(identifier: "com.example.app", version: "3.0", isSigned: true),
            SelfReplacementCandidate(identifier: "com.example.app", version: "4.0", isSigned: true)
        ]
        let result = SelfReplacementPolicy.select(
            from: copied,
            runningIdentifier: "com.example.app",
            runningVersion: "1.0"
        )
        XCTAssertEqual(result.selected, copied[1])
        XCTAssertNil(result.blocker)
    }

    func testAnEmptyLibrarySaysThereIsNoCopy() {
        let result = SelfReplacementPolicy.select(
            from: [],
            runningIdentifier: "com.example.app",
            runningVersion: "1.0"
        )
        XCTAssertNil(result.selected)
        XCTAssertEqual(result.blocker, .missing)
    }

    func testTheExplanationPrefersThisAppsCopiesOverOtherApps() {
        let copied = [
            SelfReplacementCandidate(identifier: "com.example.other", version: "9.0", isSigned: true),
            SelfReplacementCandidate(identifier: "com.example.app", version: "2.0", isSigned: false)
        ]
        let result = SelfReplacementPolicy.select(
            from: copied,
            runningIdentifier: "com.example.app",
            runningVersion: "1.0"
        )
        XCTAssertNil(result.selected)
        XCTAssertEqual(result.blocker, .notSigned, "An unrelated app must not be the explanation")
    }

    // MARK: - Copy

    func testEveryRefusalTellsTheUserWhatToDoNext() {
        for blocker in [SelfReplacementBlocker.missing, .notSigned, .notNewer, .differentApp] {
            XCTAssertGreaterThan(blocker.message.count, 40, "\(blocker.rawValue) needs a next step")
        }
    }
}
