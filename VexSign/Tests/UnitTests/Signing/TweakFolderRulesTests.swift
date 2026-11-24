//
//  TweakFolderRulesTests.swift
//  VexSignTests
//

import Foundation
import XCTest
@testable import VexSign

final class TweakFolderRulesTests: XCTestCase {
    private func name(_ desired: String, taken: [String] = [], fallback: String = "New Folder") -> String {
        TweakFolderRules.uniqueName(desired, taken: taken, fallback: fallback)
    }

    // MARK: - Names

    func testAFreeNameIsKeptExactly() {
        XCTAssertEqual(name("Tweaks"), "Tweaks")
        XCTAssertEqual(name("  Tweaks  "), "Tweaks", "surrounding whitespace is trimmed")
    }

    func testAnEmptyNameBecomesTheFallback() {
        XCTAssertEqual(name(""), "New Folder")
        XCTAssertEqual(name("   "), "New Folder")
        XCTAssertEqual(name("", fallback: "Folder"), "Folder")
    }

    func testACollisionGetsTheNextFreeSuffix() {
        XCTAssertEqual(name("Tweaks", taken: ["Tweaks"]), "Tweaks 2")
        XCTAssertEqual(name("Tweaks", taken: ["tweaks", "Tweaks 2"]), "Tweaks 3",
                       "case is ignored and occupied suffixes are skipped")
    }

    func testTheSuffixIsNotReusedAfterAGap() {
        // "Teeks 3" exists but "Teeks 2" does not: 2 is still the next free name, because the
        // number records order of creation, not a count.
        XCTAssertEqual(name("Teeks", taken: ["Teeks", "Teeks 3"]), "Teeks 2")
    }

    func testRenamingToItsOwnNameIsNotACollision() {
        // `excluding` is applied by the caller before this runs; an empty taken list is that case.
        XCTAssertEqual(name("Tweaks", taken: []), "Tweaks")
    }

    // MARK: - Deletion

    func testDeletingAFolderUncategorisesItsTweaks() {
        let deleted = UUID()
        XCTAssertNil(TweakFolderRules.folder(afterDeleting: deleted, from: deleted))
    }

    func testOtherFoldersAndUncategorisedTweaksAreUntouched() {
        let deleted = UUID()
        let other = UUID()
        XCTAssertEqual(TweakFolderRules.folder(afterDeleting: deleted, from: other), other)
        XCTAssertNil(TweakFolderRules.folder(afterDeleting: deleted, from: nil))
    }
}
