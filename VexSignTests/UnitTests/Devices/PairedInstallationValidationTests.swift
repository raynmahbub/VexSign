// Refusal tests only. These deliberately unsigned synthetic bundles can never
// establish Apple trust, successful signing, transport or device acceptance.
import Foundation
import XCTest
@testable import IDeviceSwift
@testable import VexSign

final class PairedInstallationValidationTests: XCTestCase {
    private var device: AuthorizedDeviceSnapshot {
        .init(deviceIdentifier: InstallationEvidenceTestFixtures.device, name: "Synthetic device",
              productType: "Synthetic", productVersion: "18.0", buildVersion: "Synthetic",
              services: ["Lockdown", "RSD"], observedAt: Date(), pairingSHA256: InstallationEvidenceTestFixtures.digest)
    }

    private func executable(platform: UInt32 = 2, minimumOS: UInt32 = 0x00110000,
                            cpu: UInt32 = 0x0100000c, encrypted: Bool = false) -> Data {
        var commands: [UInt32] = [0x32, 24, platform, minimumOS, 0, 0]
        if encrypted { commands += [0x2c, 24, 0, 0, 1, 0] }
        let words: [UInt32] = [0xfeedfacf, cpu, 0, 2, encrypted ? 2 : 1, UInt32(commands.count * 4), 0, 0] + commands
        var data = Data()
        for word in words {
            var value = word.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func withBundle(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("paired-admission-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: synthetic test teardown only
        let bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.example.app", "CFBundleShortVersionString": "1.2",
                    "CFBundleVersion": "7", "CFBundleExecutable": "Main", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))
        try executable().write(to: bundle.appendingPathComponent("Main"))
        try body(bundle)
    }

    private func verify(_ url: URL, identifier: String = "com.example.app", version: String = "1.2") throws {
        _ = try PairedInstallationValidation.verify(bundleAt: url, expectedIdentifier: identifier,
            expectedVersion: version, device: device)
    }

    func testIdentifierOrVersionCannotBeCopiedFromTheRequestedLibraryMetadata() throws {
        try withBundle { bundle in
            XCTAssertThrowsError(try verify(bundle, identifier: "com.example.other"))
            XCTAssertThrowsError(try verify(bundle, version: "1.3"))
        }
    }

    func testSimulatorWrongCPUEncryptedAndTooNewImagesAreRefusedBeforeProfileLoading() throws {
        try withBundle { bundle in
            for bytes in [executable(platform: 7), executable(cpu: 0x01000007),
                          executable(encrypted: true), executable(minimumOS: 0x00130000)] {
                try bytes.write(to: bundle.appendingPathComponent("Main"))
                XCTAssertThrowsError(try verify(bundle)) { error in
                    XCTAssertNotNil(error as? PairedInstallationValidation.Failure)
                }
            }
        }
    }

    func testNestedCodeIsInspectedRatherThanTrustingOnlyTheMainExecutable() throws {
        try withBundle { bundle in
            let nested = bundle.appendingPathComponent("PlugIns/Nested.appex", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.app.nested",
                "CFBundleExecutable": "Nested", "CFBundlePackageType": "XPC!"], format: .xml, options: 0)
                .write(to: nested.appendingPathComponent("Info.plist"))
            try executable(platform: 7).write(to: nested.appendingPathComponent("Nested"))
            XCTAssertThrowsError(try verify(bundle)) { error in
                XCTAssertNotNil(error as? PairedInstallationValidation.Failure)
            }
        }
    }

    func testRawPlistCannotSubstituteForAnAuthenticatedProvisioningCMS() throws {
        try withBundle { bundle in
            let raw = try PropertyListSerialization.data(fromPropertyList: ["Name": "Not an Apple profile"], format: .xml, options: 0)
            try raw.write(to: bundle.appendingPathComponent("embedded.mobileprovision"))
            XCTAssertThrowsError(try verify(bundle)) { error in
                guard let error = error as? ProvisioningProfileParser.Failure,
                      case .untrustedCMS = error else { return XCTFail("Unauthenticated input must stop at the real CMS gate") }
            }
        }
    }

    func testSymbolicLinksCannotEscapeTheCopiedSigningManifest() throws {
        try withBundle { bundle in
            let outside = bundle.deletingLastPathComponent().appendingPathComponent("outside")
            try Data("unrelated file".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("escape"), withDestinationURL: outside)
            XCTAssertThrowsError(try verify(bundle)) { error in
                XCTAssertNotNil(error as? PairedInstallationValidation.Failure)
            }
        }
    }
}
