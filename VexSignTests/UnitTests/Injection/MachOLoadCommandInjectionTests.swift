//
//  MachOLoadCommandInjectionTests.swift
//  VexSignTests
//
//  Hand-built Mach-O fixtures. No imported executable is loaded or executed.
//

import Foundation
import XCTest
@testable import VexSign

final class MachOLoadCommandInjectionTests: XCTestCase {
    private let loadPath = "@executable_path/Frameworks/Fixture.dylib"

    func testThinBinaryPlanAppliesAndIsReadBack() throws {
        let original = InjectionFixtures.machO()
        let plans = try MachOLoadCommandInjector.plan(in: original, loadPath: loadPath)
        XCTAssertEqual(plans.count, 1)
        XCTAssertFalse(MachOReader.dylibs(in: original).contains(loadPath))

        let modified = try plans[0].apply(to: original)
        XCTAssertNotEqual(modified, original)
        XCTAssertTrue(MachOReader.dylibs(in: modified).contains(loadPath))
        XCTAssertEqual(modified.count, original.count)
    }

    func testDuplicateLoadPathIsRefused() {
        let original = InjectionFixtures.machO(loadPaths: [loadPath])
        XCTAssertThrowsError(try MachOLoadCommandInjector.plan(in: original, loadPath: loadPath)) { error in
            XCTAssertEqual(error as? MachOLoadCommandError, .duplicateLoadPath)
        }
    }

    func testInsufficientSlackIsRefused() {
        // Section data starts immediately after the load commands: inserting a
        // command would overwrite the first section, so no plan is permitted.
        let original = InjectionFixtures.machO(sectionOffset: 208)
        XCTAssertThrowsError(try MachOLoadCommandInjector.plan(in: original, loadPath: loadPath)) { error in
            XCTAssertEqual(error as? MachOLoadCommandError, .insufficientLoadCommandSpace)
        }
    }

    func testMalformedHeaderIsRefused() {
        XCTAssertThrowsError(try MachOLoadCommandInjector.plan(in: Data([0x01, 0x02, 0x03, 0x04]), loadPath: loadPath)) { error in
            XCTAssertEqual(error as? MachOLoadCommandError, .unsupportedHeader)
        }
    }

    func testInvalidLoadPathIsRefused() {
        XCTAssertThrowsError(try MachOLoadCommandInjector.plan(in: InjectionFixtures.machO(), loadPath: "")) { error in
            XCTAssertEqual(error as? MachOLoadCommandError, .invalidLoadPath)
        }
        XCTAssertThrowsError(try MachOLoadCommandInjector.plan(
            in: InjectionFixtures.machO(), loadPath: "/bad\npath"
        )) { error in
            XCTAssertEqual(error as? MachOLoadCommandError, .invalidLoadPath)
        }
    }

    func testUniversalBinaryPreservesSliceOffsets() throws {
        let first = InjectionFixtures.machO()
        let second = InjectionFixtures.machO(loadPaths: ["@rpath/Other.dylib"])
        let fat = InjectionFixtures.fat(slices: [first, second])
        let plans = try MachOLoadCommandInjector.plan(in: fat, loadPath: loadPath)
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans.map(\.sliceOffset), [28, 28 + first.count])

        var modified = fat
        for plan in plans.reversed() {
            let sliceRange = plan.sliceOffset..<(plan.sliceOffset + first.count)
            let slice = Data(fat[sliceRange])
            let newSlice = try plan.apply(to: slice)
            modified.replaceSubrange(sliceRange, with: newSlice)
        }
        XCTAssertEqual(modified.count, fat.count)
        let inspection = MachOInspector.inspect(modified)
        XCTAssertEqual(inspection.slices.count, 2)
        XCTAssertTrue(inspection.resolvedLinkedLibraries.contains(loadPath))
    }

    func testExistingCodeSignatureIsInvalidated() throws {
        let original = InjectionFixtures.machO(includeCodeSignature: true)
        let plan = try XCTUnwrap(MachOLoadCommandInjector.plan(in: original, loadPath: loadPath).first)
        let modified = try plan.apply(to: original)
        let inspection = MachOInspector.inspect(modified)
        XCTAssertFalse(inspection.slices.first?.hasCodeSignature ?? true)
        XCTAssertTrue(MachOReader.dylibs(in: modified).contains(loadPath))
    }

    func testVerificationDetectsMissingLoadCommand() throws {
        let original = InjectionFixtures.machO()
        let modified = try XCTUnwrap(MachOLoadCommandInjector.plan(in: original, loadPath: loadPath).first).apply(to: original)
        XCTAssertTrue(MachOReader.dylibs(in: modified).contains(loadPath))
        XCTAssertFalse(MachOReader.dylibs(in: original).contains(loadPath), "the original must stay untouched")
    }
}
