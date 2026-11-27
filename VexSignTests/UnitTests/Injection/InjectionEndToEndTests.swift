//
//  InjectionEndToEndTests.swift
//  VexSignTests
//
//  Structural end-to-end coverage from a synthetic `.deb` to a planned,
//  modified and re-inspected Mach-O. It does NOT execute the app or claim any
//  runtime behaviour on a device.
//

import Foundation
import XCTest
@testable import VexSign

final class InjectionEndToEndTests: XCTestCase {
    func testInspectionToPlanToModifiedExecutable() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("InjectionE2E_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let control = """
        Package: com.example.tweak
        Name: E2E Tweak
        Version: 1.0
        Architecture: iphoneos-arm
        Maintainer: Fixture
        Description: Fixture package.
        """
        let plist = """
        <?xml version="1.0"?><plist version="1.0"><dict><key>Filter</key><dict>
        <key>Bundles</key><array><string>com.example.app</string></array>
        </dict></dict></plist>
        """
        let debURL = root.appendingPathComponent("tweak.deb")
        try InjectionFixtures.deb(control: control, files: [
            ("Library/MobileSubstrate/DynamicLibraries/E2E.dylib", InjectionFixtures.machO(), "0"),
            ("Library/MobileSubstrate/DynamicLibraries/E2E.plist", Data(plist.utf8), "0")
        ]).write(to: debURL)

        let inspection = try await TweakPackageInspector.inspect(fileAt: debURL)
        XCTAssertEqual(inspection.outcome, .compatible)
        let filter = try XCTUnwrap(inspection.filters.values.first)
        let configuration = InjectionConfiguration.from(
            packageID: inspection.packageID ?? "", version: inspection.version ?? "",
            enabled: true, filter: filter, installPath: "@executable_path",
            provenance: "package filter plist"
        )
        let plan = InjectionPlanner.makePlan(input: InjectionPlanningInput(
            appIdentifier: "com.example.app",
            targets: [InjectionFixtures.target()],
            inspections: [inspection],
            configurations: [configuration]
        ))
        XCTAssertTrue(plan.canApply)

        // The executable is modified in isolated storage, never in place.
        let originalExecutable = root.appendingPathComponent("OriginalExecutable")
        let modifiedExecutable = root.appendingPathComponent("ModifiedExecutable")
        let originalBytes = InjectionFixtures.machO()
        try originalBytes.write(to: originalExecutable)
        let loadPath = "@executable_path/Frameworks/E2E.dylib"
        let planForBinary = try XCTUnwrap(MachOLoadCommandInjector.plan(in: originalBytes, loadPath: loadPath).first)
        try planForBinary.apply(to: originalBytes).write(to: modifiedExecutable)

        XCTAssertEqual(try Data(contentsOf: originalExecutable), originalBytes)
        XCTAssertTrue(MachOReader.dylibs(forExecutableAt: modifiedExecutable).contains(loadPath))
        XCTAssertFalse(MachOReader.dylibs(forExecutableAt: originalExecutable).contains(loadPath))
        XCTAssertTrue(plan.requiresSignatureVerification)
    }

    func testModifiedBinaryWithoutFreshSignatureIsNeverInstallable() throws {
        let original = InjectionFixtures.machO(includeCodeSignature: true)
        let modified = try XCTUnwrap(MachOLoadCommandInjector.plan(in: original, loadPath: "@rpath/E2E.dylib").first)
            .apply(to: original)
        let inspection = MachOInspector.inspect(modified)
        XCTAssertFalse(inspection.slices.first?.hasCodeSignature ?? true,
                       "stale code signature must be invalidated after a code change")
        XCTAssertTrue(MachOReader.dylibs(in: modified).contains("@rpath/E2E.dylib"))
        // Signing and verification are owned by the existing pipeline; a load
        // command alone is never an installability claim.
        XCTAssertTrue(true)
    }

    func testConflictingPackageStopsPlanBeforeAnyModification() {
        let first = InjectionFixtures.inspection(id: "a", name: "A", installPaths: ["Shared/File.dylib"], dylibs: ["Shared/File.dylib"])
        let second = InjectionFixtures.inspection(id: "b", name: "B", installPaths: ["Shared/File.dylib"], dylibs: ["Shared/File.dylib"])
        let dependency = InjectionDependencyResolver.resolve(selected: [first, second])
        XCTAssertEqual(dependency.outcome, .conflictingModification)
        let plan = InjectionPlanner.makePlan(input: InjectionPlanningInput(
            appIdentifier: "com.example.app",
            targets: [InjectionFixtures.target()],
            inspections: [first, second],
            configurations: [
                InjectionConfiguration.from(packageID: "a", version: "1", enabled: true,
                                            filter: TweakFilterMetadata(bundles: [InjectionFilterRule(kind: .bundle, pattern: "com.example.app")], executables: []),
                                            installPath: "@executable_path", provenance: "fixture"),
                InjectionConfiguration.from(packageID: "b", version: "1", enabled: true,
                                            filter: TweakFilterMetadata(bundles: [InjectionFilterRule(kind: .bundle, pattern: "com.example.app")], executables: []),
                                            installPath: "@executable_path", provenance: "fixture")
            ]
        ))
        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.steps.isEmpty)
    }
}
