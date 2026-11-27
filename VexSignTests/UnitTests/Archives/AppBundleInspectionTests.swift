// Synthetic app bundles only. Every fixture is generated in a temporary
// directory; no production IPA, certificate or personal account is used.
import Foundation
import XCTest
import ZIPFoundation
@testable import VexSign

final class AppBundleInspectionTests: XCTestCase {
    private var root: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent("InspectionTests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: root)
    }

    private func makeDirectory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePlist(_ dictionary: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func machO(encrypted: Bool = false, signed: Bool = true) -> Data {
        var commands: [UInt32] = [0x32, 24, 2, 0x000f_0000, 0, 0] // build version, iOS, min 15.0
        if encrypted { commands += [0x2c, 24, 0, 0, 1, 0] }
        if signed { commands += [0x1d, 16, 0, 0] }
        let words: [UInt32] = [0xfeed_facf, 0x0100_000c, 0, 2, 1,
                               UInt32(commands.count * 4), 0, 0] + commands
        var data = Data()
        for word in words {
            var value = word.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    @discardableResult
    private func makeApp(
        identifier: String = "com.example.app",
        includeExecutable: Bool = true,
        includePlist: Bool = true,
        executableData: Data? = nil,
        extra: [String: Any] = [:]
    ) throws -> URL {
        let app = try makeDirectory("Payload/Test.app")
        var plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Test",
            "CFBundleDisplayName": "Test App",
            "CFBundleExecutable": "Test",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "2.1.0",
            "CFBundleVersion": "42",
            "MinimumOSVersion": "15.0",
            "DTPlatformName": "iphoneos",
            "DTPlatformVersion": "17.0",
            "UIDeviceFamily": [1, 2],
            "CFBundleIconFile": "AppIcon.png",
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["testapp"]]],
            "CFBundleDocumentTypes": [["CFBundleTypeName": "Test Document"]],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"]
        ]
        for (key, value) in extra { plist[key] = value }
        if includePlist {
            try writePlist(plist, to: app.appendingPathComponent("Info.plist"))
        }
        if includeExecutable {
            try (executableData ?? machO()).write(to: app.appendingPathComponent("Test"))
        }
        return app
    }

    func testMinimalAppExtractsIdentityVersionPlatformAndIntegration() throws {
        let app = try makeApp()
        let result = AppBundleInspector.inspect(appBundle: app)
        XCTAssertEqual(result.report.status, .valid)
        XCTAssertEqual(result.report.identity.bundleIdentifier, "com.example.app")
        XCTAssertEqual(result.report.version.shortVersion, "2.1.0")
        XCTAssertEqual(result.report.version.build, "42")
        XCTAssertEqual(result.report.platform.minimumOSVersion, "15.0")
        XCTAssertEqual(result.report.platform.deviceFamilies, [1, 2])
        XCTAssertEqual(result.report.presentation.iconFiles, ["AppIcon.png"])
        XCTAssertEqual(result.report.integration.urlSchemes, ["testapp"])
        XCTAssertEqual(result.report.integration.documentTypes, ["Test Document"])
        XCTAssertEqual(result.report.integration.capabilities, [])
        XCTAssertEqual(result.report.executable.architectures, ["arm64"])
        XCTAssertEqual(result.report.executable.minimumOSVersion, "15.0")
        XCTAssertEqual(result.report.executable.platform, "iOS")
        XCTAssertTrue(result.report.executable.hasCodeSignature)
        XCTAssertFalse(result.report.signature.hasSignatureDirectory)
        XCTAssertEqual(result.report.signature.status, .structuralOnly)
        XCTAssertTrue(result.report.isImportable)
    }

    func testExistingSignatureRequiresCodeResourcesForStructuralEvidence() throws {
        let app = try makeApp(executableData: machO(signed: false))
        var result = AppBundleInspector.inspect(appBundle: app)
        XCTAssertEqual(result.report.signature.status, .absent)

        let seal = try makeDirectory("Payload/Test.app/_CodeSignature")
        try Data("seal".utf8).write(to: seal.appendingPathComponent("CodeResources"))
        result = AppBundleInspector.inspect(appBundle: app)
        XCTAssertEqual(result.report.signature.status, .structuralOnly)
        XCTAssertTrue(result.report.signature.hasCodeResources)
    }

    func testIncompleteSignatureDirectoryIsInvalid() throws {
        let app = try makeApp(executableData: machO(signed: false))
        _ = try makeDirectory("Payload/Test.app/_CodeSignature")
        let result = AppBundleInspector.inspect(appBundle: app)
        XCTAssertEqual(result.report.status, .invalid)
        XCTAssertEqual(result.report.signature.status, .invalid)
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == "signature-incomplete" })
    }

    func testNestedBundlesAreClassifiedWithoutBecomingMainCandidates() throws {
        let app = try makeApp()
        let plugin = try makeDirectory("Payload/Test.app/PlugIns/Widget.appex")
        try writePlist(["CFBundleIdentifier": "com.example.widget", "CFBundleExecutable": "Widget",
                        "CFBundleName": "Widget"], to: plugin.appendingPathComponent("Info.plist"))
        try machO().write(to: plugin.appendingPathComponent("Widget"))
        let watch = try makeDirectory("Payload/Test.app/Watch/WatchApp.watchapp")
        try writePlist(["CFBundleIdentifier": "com.example.watch", "CFBundleExecutable": "Watch"],
                       to: watch.appendingPathComponent("Info.plist"))
        try machO().write(to: watch.appendingPathComponent("Watch"))
        let framework = try makeDirectory("Payload/Test.app/Frameworks/Lib.framework")
        try writePlist(["CFBundleIdentifier": "com.example.lib", "CFBundleExecutable": "Lib"],
                       to: framework.appendingPathComponent("Info.plist"))
        try machO().write(to: framework.appendingPathComponent("Lib"))
        try machO().write(to: app.appendingPathComponent("Frameworks/dylib.dylib"))

        let result = AppBundleInspector.inspect(appBundle: app)
        XCTAssertEqual(result.report.status, .valid)
        let kinds = Dictionary(uniqueKeysWithValues: result.report.nestedBundles.map {
            ($0.relativePath, $0.kind)
        })
        XCTAssertEqual(kinds["Payload/Test.app/PlugIns/Widget.appex"], .appExtension)
        XCTAssertEqual(kinds["Payload/Test.app/Watch/WatchApp.watchapp"], .watchApplication)
        XCTAssertEqual(kinds["Payload/Test.app/Frameworks/Lib.framework"], .framework)
        XCTAssertEqual(kinds["Payload/Test.app/Frameworks/dylib.dylib"], .dynamicLibrary)
        XCTAssertEqual(result.report.nestedBundles.first(where: { $0.kind == .appExtension })?.bundleIdentifier,
                       "com.example.widget")
    }

    func testDuplicateNestedIdentifierIsAmbiguousNotSilentlyAccepted() throws {
        let app = try makeApp()
        let plugin = try makeDirectory("Payload/Test.app/PlugIns/Widget.appex")
        try writePlist(["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Widget"],
                       to: plugin.appendingPathComponent("Info.plist"))
        try machO().write(to: plugin.appendingPathComponent("Widget"))
        let result = AppBundleInspector.inspect(appBundle: app)
        XCTAssertEqual(result.report.status, .ambiguous)
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == "duplicate-bundle-identifier" })
    }

    func testMissingMetadataAndExecutableAreRejected() throws {
        let noPlist = try makeApp(includePlist: false)
        XCTAssertEqual(AppBundleInspector.inspect(appBundle: noPlist).report.status, .invalid)

        let noExecutable = try makeApp(includeExecutable: false)
        let result = AppBundleInspector.inspect(appBundle: noExecutable)
        XCTAssertEqual(result.report.status, .invalid)
        XCTAssertTrue(result.report.diagnostics.contains { $0.code == "executable-missing" })
    }

    func testMalformedAndEncryptedExecutablesAreClassified() throws {
        let malformed = try makeApp(executableData: Data("not mach-o".utf8))
        let malformedReport = AppBundleInspector.inspect(appBundle: malformed).report
        XCTAssertEqual(malformedReport.status, .invalid)
        XCTAssertTrue(malformedReport.diagnostics.contains { $0.code == "executable-malformed" })

        let encrypted = try makeApp(executableData: machO(encrypted: true))
        let encryptedReport = AppBundleInspector.inspect(appBundle: encrypted).report
        XCTAssertEqual(encryptedReport.status, .valid)
        XCTAssertTrue(encryptedReport.executable.isEncrypted)
        XCTAssertTrue(encryptedReport.executable.diagnostics.contains { $0.code == "executable-encrypted" })
    }

    func testOriginalMetadataIsStoredBesideTheBundleNotInsideIt() throws {
        let app = try makeApp()
        let library = app.deletingLastPathComponent()
        let result = AppBundleInspector.inspect(appBundle: app)
        let directory = try ImportInspectionStore.write(result, to: library)

        XCTAssertEqual(directory.lastPathComponent, "Inspection")
        XCTAssertFalse(manager.fileExists(atPath: app.appendingPathComponent("Inspection").path))
        XCTAssertEqual(ImportInspectionStore.read(from: library)?.identity.bundleIdentifier, "com.example.app")
        XCTAssertEqual(ImportInspectionStore.originalInfoPlist(from: library), result.originalInfoPlist)

        ImportInspectionStore.remove(from: library)
        XCTAssertNil(ImportInspectionStore.read(from: library))
    }

    func testArchiveSummaryUsesTheSharedValidatorAndRecordsRealEntries() throws {
        let input = try makeDirectory("ZipInput")
        let payload = try makeDirectory("ZipInput/Payload")
        let app = try makeDirectory("ZipInput/Payload/Test.app")
        try writePlist(["CFBundleIdentifier": "com.example.app"], to: app.appendingPathComponent("Info.plist"))
        try machO().write(to: app.appendingPathComponent("Test"))
        let ipa = root.appendingPathComponent("Summary.ipa")
        let archive = try Archive(url: ipa, accessMode: .create)
        try archive.addEntry(with: "Payload/", relativeTo: input)
        try archive.addEntry(with: "Payload/Test.app/", relativeTo: input)
        try archive.addEntry(with: "Payload/Test.app/Info.plist", relativeTo: input)
        try archive.addEntry(with: "Payload/Test.app/Test", relativeTo: input)

        let summary = try IPAArchiveInspector.summarize(ipa)
        XCTAssertEqual(summary.entryCount, 4)
        XCTAssertTrue(summary.hasPayloadDirectory)
        XCTAssertEqual(summary.payloadAppBundleCount, 1)
        XCTAssertGreaterThan(summary.totalExpandedBytes, 0)
        XCTAssertEqual(summary.largestEntryPath, "Payload/Test.app/Test")
        XCTAssertFalse(summary.compressionMethods.isEmpty)
    }

    func testMalformedProfileDoesNotInvalidateTheAppButIsReported() throws {
        let app = try makeApp()
        try Data("not a CMS profile".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
        let report = AppBundleInspector.inspect(appBundle: app).report
        XCTAssertEqual(report.status, .valid)
        XCTAssertTrue(report.signature.profilePresent)
        XCTAssertFalse(report.signature.profileReadable)
        XCTAssertTrue(report.signature.diagnostics.contains { $0.code == "profile-unreadable" })
        XCTAssertNotEqual(report.signature.status, .cryptographicallyVerified)
    }
}
