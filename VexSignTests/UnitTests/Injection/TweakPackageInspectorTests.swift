//
//  TweakPackageInspectorTests.swift
//  VexSignTests
//
//  Synthetic Debian packages: no real tweak payloads or scripts are executed.
//

import Foundation
import XCTest
@testable import VexSign

final class TweakPackageInspectorTests: XCTestCase {
    private func writeDeb(_ data: Data, name: String = "fixture.deb") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InspectTest_\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func validControl(depends: String = "") -> String {
        """
        Package: com.example.tweak
        Name: Example Tweak
        Version: 1.2
        Architecture: iphoneos-arm64
        Maintainer: Fixture Maintainer <fixture@example.invalid>
        Depends: mobilesubstrate\(depends.isEmpty ? "" : ", " + depends)
        Description: A deterministic test package.
        """
    }

    private func payload() -> [(String, Data, String)] {
        [
            ("Library/MobileSubstrate/DynamicLibraries/Example.dylib", Data([0xca, 0xfe]), "0"),
            ("Library/MobileSubstrate/DynamicLibraries/Example.plist", Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict><key>Filter</key><dict>
                <key>Bundles</key><array><string>com.example.app</string></array>
                <key>Executables</key><array><string>ExampleApp</string></array>
                </dict></dict></plist>
                """.utf8), "0")
        ]
    }

    func testValidPackageExposesMetadataPayloadAndFilters() async throws {
        let url = try writeDeb(InjectionFixtures.deb(control: validControl(), files: payload()))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let report = try await TweakPackageInspector.inspect(fileAt: url)
        XCTAssertEqual(report.packageID, "com.example.tweak")
        XCTAssertEqual(report.name, "Example Tweak")
        XCTAssertEqual(report.version, "1.2")
        XCTAssertEqual(report.architecture, "iphoneos-arm64")
        XCTAssertEqual(report.depends.map(\.name), ["mobilesubstrate"])
        XCTAssertTrue(report.dylibs.contains { $0.hasSuffix("Example.dylib") })
        XCTAssertEqual(report.filters.count, 1)
        XCTAssertEqual(report.filters.values.first?.bundles.first?.pattern, "com.example.app")
        XCTAssertEqual(report.layout, .rootful)
    }

    func testMalformedEnvelopeIsRejected() async throws {
        let url = try writeDeb(Data("not a deb".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            _ = try await TweakPackageInspector.inspect(fileAt: url)
            XCTFail("a malformed envelope must be refused")
        } catch let error as TweakPackageInspectorError {
            guard case .invalidEnvelope = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testMissingMetadataIsRejected() async throws {
        let control = "Name: No Identifier\nVersion: 1.0\nArchitecture: iphoneos-arm64\n"
        let url = try writeDeb(InjectionFixtures.deb(control: control, files: payload()))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            _ = try await TweakPackageInspector.inspect(fileAt: url)
            XCTFail("missing Package field must be refused")
        } catch TweakPackageInspectorError.missingControl { }
    }

    func testUnsupportedArchitectureIsReported() async throws {
        let control = validControl().replacingOccurrences(of: "iphoneos-arm64", with: "linux-amd64")
        let url = try writeDeb(InjectionFixtures.deb(control: control, files: payload()))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try await TweakPackageInspector.inspect(fileAt: url)
        XCTAssertTrue(report.findings.contains { $0.code.contains("layoutMismatch") || $0.code.contains("unsupported") }
                      || report.layout == .rootful)
    }

    func testPathTraversalAndSymlinkAreRejected() async throws {
        let url = try writeDeb(InjectionFixtures.deb(control: validControl(), files: [
            ("../escape.dylib", Data([0x01]), "0")
        ]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            _ = try await TweakPackageInspector.inspect(fileAt: url)
            XCTFail("traversal must be refused")
        } catch TweakPackageInspectorError.extractionFailed(_) { }

        let linkURL = try writeDeb(InjectionFixtures.deb(control: validControl(), files: [
            ("Library/MobileSubstrate/DynamicLibraries/Link.dylib", Data("/etc/passwd".utf8), "2")
        ]), name: "link.deb")
        defer { try? FileManager.default.removeItem(at: linkURL.deletingLastPathComponent()) }
        do {
            _ = try await TweakPackageInspector.inspect(fileAt: linkURL)
            XCTFail("symlink must be refused")
        } catch TweakPackageInspectorError.extractionFailed(_) { }
    }

    func testExtractionLimitsAreEnforced() async throws {
        let url = try writeDeb(InjectionFixtures.deb(control: validControl(), files: payload()))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var limits = StrictTarExtractor.Limits.default
        limits.maximumExpandedBytes = 8
        do {
            _ = try await TweakPackageInspector.inspect(fileAt: url, limits: limits)
            XCTFail("expansion limit must be enforced")
        } catch TweakPackageInspectorError.extractionFailed(let detail) {
            XCTAssertTrue(detail.contains("limit") || detail.contains("safely"))
        }
    }

    func testScriptsAreNeverInstalledOrExecuted() async throws {
        var files = payload()
        files.append(("DEBIAN/postinst", Data("#!/bin/sh\necho executed".utf8), "0"))
        let url = try writeDeb(InjectionFixtures.deb(control: validControl(), files: files))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try await TweakPackageInspector.inspect(fileAt: url)
        XCTAssertEqual(report.ignoredScripts, ["postinst"])
        XCTAssertTrue(report.outcome == .requiresAdditionalValidation || report.outcome == .compatible)
    }

    func testDependencyRelationParsingHandlesConstraintsAndAlternatives() {
        let relations = PackageRelationParser.parse("mobilesubstrate (>= 0.9), firmware (>= 15.0), a | b")
        XCTAssertEqual(relations.count, 3)
        XCTAssertEqual(relations[0].name, "mobilesubstrate")
        XCTAssertEqual(relations[0].versionConstraint, "(>= 0.9)")
        XCTAssertEqual(relations[2].name, "a | b")
    }

    func testMalformedFilterBlocksInjectionInsteadOfWideningIt() async throws {
        let badPlist = """
        <?xml version="1.0"?><plist version="1.0"><dict><key>Filter</key><dict>
        <key>Bundles</key><array><string>com.example.app/../../*</string></array>
        </dict></dict></plist>
        """
        let url = try writeDeb(InjectionFixtures.deb(control: validControl(), files: [
            ("Library/MobileSubstrate/DynamicLibraries/Example.dylib", Data([0x01]), "0"),
            ("Library/MobileSubstrate/DynamicLibraries/Example.plist", Data(badPlist.utf8), "0")
        ]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try await TweakPackageInspector.inspect(fileAt: url)
        XCTAssertFalse(report.filterErrors.isEmpty)
        XCTAssertEqual(report.outcome, .invalidPackage)
    }
}
