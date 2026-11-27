//
//  InjectionConfigurationAndPlannerTests.swift
//  VexSignTests
//

import Foundation
import XCTest
@testable import VexSign

final class InjectionConfigurationAndPlannerTests: XCTestCase {
    func testInclusionFilterSelectsMatchingBundleOnly() {
        let result = InjectionConfigurationEngine.evaluate(
            configurations: [InjectionFixtures.configuration()],
            targets: [InjectionFixtures.target(), InjectionFixtures.target(id: "other", bundleID: "com.other.app", executable: "Other")],
            executableInstallNames: ["main": "@executable_path/ExampleApp"]
        )
        XCTAssertEqual(result.outcome, .compatible)
        XCTAssertEqual(result.selections.count, 1)
        XCTAssertEqual(result.selections.first?.targetID, "main")
    }

    func testExecutableFilterMatchesInstallName() {
        var configuration = InjectionFixtures.configuration()
        configuration = InjectionConfiguration(
            packageID: configuration.packageID, version: configuration.version,
            enabled: true, bundleRules: [],
            executableRules: [InjectionFilterRule(kind: .executable, pattern: "Frameworks/Fixture.dylib")],
            excludedBundleIDs: [], installPath: "@rpath", provenance: "fixture"
        )
        let result = InjectionConfigurationEngine.evaluate(
            configurations: [configuration],
            targets: [InjectionFixtures.target()],
            executableInstallNames: ["main": "@rpath/Frameworks/Fixture.dylib"]
        )
        XCTAssertEqual(result.selections.count, 1)
    }

    func testExclusionWinsOverInclusion() {
        let result = InjectionConfigurationEngine.evaluate(
            configurations: [InjectionFixtures.configuration(excluded: ["com.example.app"])],
            targets: [InjectionFixtures.target()]
        )
        XCTAssertTrue(result.selections.isEmpty)
        XCTAssertTrue(result.explanations.contains { $0.contains("excluded") })
    }

    func testMalformedFilterNeverInjectsEverywhere() {
        let configuration = InjectionConfiguration(
            packageID: "bad", version: "1", enabled: true,
            bundleRules: [InjectionFilterRule(kind: .bundle, pattern: "com.example.app/../../*")],
            executableRules: [], excludedBundleIDs: [], installPath: "@executable_path", provenance: "fixture"
        )
        let result = InjectionConfigurationEngine.evaluate(
            configurations: [configuration], targets: [InjectionFixtures.target()]
        )
        XCTAssertEqual(result.outcome, .invalidPackage)
        XCTAssertTrue(result.selections.isEmpty)
    }

    func testContradictoryRuleIsConflicting() {
        let result = InjectionConfigurationEngine.evaluate(
            configurations: [InjectionFixtures.configuration(excluded: ["com.example.app"])],
            targets: [InjectionFixtures.target()]
        )
        XCTAssertTrue(result.explanations.contains { $0.contains("contradictory") })
    }

    func testMissingTargetRequiresValidation() {
        let result = InjectionConfigurationEngine.evaluate(
            configurations: [InjectionFixtures.configuration(pattern: "com.not.present")],
            targets: [InjectionFixtures.target()]
        )
        XCTAssertEqual(result.outcome, .requiresAdditionalValidation)
        XCTAssertTrue(result.selections.isEmpty)
    }

    func testDependencyResolverDetectsMissingDependency() {
        let result = InjectionDependencyResolver.resolve(
            selected: [InjectionFixtures.inspection(depends: ["mobilesubstrate (>= 0.9)"])]
        )
        XCTAssertEqual(result.outcome, .missingDependency)
        XCTAssertEqual(result.unmet, ["mobilesubstrate"])
        XCTAssertTrue(result.requiredRuntimeLibraries.contains("mobilesubstrate"))
    }

    func testDependencyResolverDetectsConflictsAndCycles() {
        let result = InjectionDependencyResolver.resolve(selected: [
            InjectionFixtures.inspection(id: "a", name: "A", depends: ["b"], conflicts: ["b"]),
            InjectionFixtures.inspection(id: "b", name: "B", depends: ["a"])
        ])
        XCTAssertFalse(result.cycles.isEmpty)
        XCTAssertFalse(result.conflicts.isEmpty)
        XCTAssertEqual(result.outcome, .conflictingModification)
    }

    func testPlanRequiresVerificationAndBlocksOnInvalidBinary() {
        let input = InjectionPlanningInput(
            appIdentifier: "com.example.app",
            targets: [InjectionFixtures.target()],
            inspections: [InjectionFixtures.inspection()],
            configurations: [InjectionFixtures.configuration()],
            binaryFindings: [InjectionFinding(code: "malformedLoadCommands", severity: .blocking, detail: "bad binary")]
        )
        let plan = InjectionPlanner.makePlan(input: input)
        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.requiresSignatureVerification)
        XCTAssertTrue(plan.findings.contains { $0.code == "malformedLoadCommands" })
    }

    func testPlanWithValidConfigurationContainsOrderAndVerificationSteps() {
        let input = InjectionPlanningInput(
            appIdentifier: "com.example.app",
            targets: [InjectionFixtures.target()],
            inspections: [InjectionFixtures.inspection()],
            configurations: [InjectionFixtures.configuration()]
        )
        let plan = InjectionPlanner.makePlan(input: input)
        XCTAssertEqual(plan.outcome, .compatible)
        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.selectedPackageIDs, ["com.example.tweak"])
        XCTAssertTrue(plan.steps.contains { $0.kind == .placePayload })
        XCTAssertTrue(plan.steps.contains { $0.kind == .addLoadCommand })
        XCTAssertEqual(plan.steps.last?.kind, .verifySignature)
    }

    func testNestedTargetRequiresNestedSigningStep() {
        let input = InjectionPlanningInput(
            appIdentifier: "com.example.app",
            targets: [
                InjectionFixtures.target(),
                InjectionFixtures.target(id: "extension-1", bundleID: "com.example.app.widget", executable: "Widget", isMain: false)
            ],
            inspections: [InjectionFixtures.inspection()],
            configurations: [InjectionFixtures.configuration()]
        )
        let plan = InjectionPlanner.makePlan(input: input)
        XCTAssertTrue(plan.steps.contains { $0.kind == .reSignNestedCode && $0.targetID == "extension-1" })
    }

    func testWorkspaceDiscardsOnlyItsOwnTemporaryFiles() async throws {
        let workspace = try InjectionWorkspace(label: "InjectionTest")
        let directory = workspace.directory
        let source = directory.appendingPathComponent("source.bin")
        try Data([0x01]).write(to: source)
        let staged = try await workspace.stage(source, as: "copy.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(staged.lastPathComponent, "copy.bin")
        try await workspace.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

extension InjectionConfigurationAndPlannerTests {
    func testAuthorizationGateRefusesUnselectedBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuthGate_\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))

        let result = InjectionTargetAuthorization.evaluate(
            configurations: [InjectionFixtures.configuration(pattern: "com.another.app")],
            in: app, bundleIdentifier: nil
        )
        XCTAssertEqual(result.outcome, .requiresAdditionalValidation)
        XCTAssertTrue(result.selections.isEmpty)
    }

    func testAuthorizationGateAcceptsMatchingBundleAndNestedTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuthGateOK_\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Fixture.app")
        let plugin = app.appendingPathComponent("PlugIns/Widget.appex")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))

        let configuration = InjectionConfiguration(
            packageID: "fixture", version: "1", enabled: true,
            bundleRules: [InjectionFilterRule(kind: .bundle, pattern: "com.example.app*")],
            executableRules: [], excludedBundleIDs: [], installPath: "@executable_path", provenance: "fixture"
        )
        let targets = InjectionTargetAuthorization.targets(in: app, bundleIdentifier: nil)
        XCTAssertEqual(targets.count, 2)
        let result = InjectionConfigurationEngine.evaluate(configurations: [configuration], targets: targets)
        XCTAssertEqual(result.outcome, .compatible)
        XCTAssertEqual(result.selections.count, 2)
    }

    func testBinaryAdmissionRejectsUnsupportedLayoutBeforeMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Admission_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("malformed")
        try Data("not a mach-o".utf8).write(to: executable)
        XCTAssertThrowsError(try InjectionBinaryAdmission.validate(
            executableAt: executable, proposedLoadPath: "@executable_path/Frameworks/Probe.dylib"
        )) { error in
            guard case InjectionBinaryAdmissionError.unsupportedLayout = error else {
                return XCTFail("unsupported layout must be refused: \(error)")
            }
        }
    }

    func testBinaryAdmissionAcceptsVerifiedArm64Layout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdmissionOK_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("arm64")
        try InjectionFixtures.machO().write(to: executable)
        XCTAssertNoThrow(try InjectionBinaryAdmission.validate(
            executableAt: executable, proposedLoadPath: "@executable_path/Frameworks/Probe.dylib"
        ))
    }

    func testOptionsKeepStructuredConfigurationsAcrossDecode() throws {
        var options = Options.defaultOptions
        options.injectionConfigurations = [InjectionFixtures.configuration()]
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(Options.self, from: data)
        XCTAssertEqual(decoded.injectionConfigurations, options.injectionConfigurations)
        XCTAssertTrue(Options.defaultOptions.injectionConfigurations.isEmpty)
        XCTAssertTrue(decoded.withoutPerAppFields().injectionConfigurations.isEmpty,
                      "per-run rules must not be saved as global signing defaults")
    }
}
