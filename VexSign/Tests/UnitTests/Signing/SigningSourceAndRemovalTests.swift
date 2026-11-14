import XCTest
@testable import VexSign

final class SigningSourceAndRemovalTests: XCTestCase {
    private var root: URL!
    private var app: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SigningSource-" + UUID().uuidString)
        app = root.appendingPathComponent("Original.app")
        try SigningRegressionFixture.bundle(at: app)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        app = nil; root = nil
    }

    private func write(_ bytes: Data, path: String) throws {
        let file = app.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
    }

    private func extensionBundle(_ name: String = "Share", point: String? = "com.apple.share-services") throws -> URL {
        let url = app.appendingPathComponent("PlugIns/" + name + ".appex")
        try SigningRegressionFixture.bundle(at: url, identifier: "com.example.app." + name.lowercased())
        var plist: [String: Any] = ["CFBundleIdentifier": "com.example.app." + name.lowercased(),
            "CFBundleExecutable": "Fixture", "CFBundlePackageType": "XPC!"]
        if let point { plist["NSExtension"] = ["NSExtensionPointIdentifier": point] }
        try SigningRegressionFixture.plist(plist).write(to: url.appendingPathComponent("Info.plist"))
        return url
    }

    func testSourceFingerprintIsCopyStableButBindsResourceAndExecutableBytes() throws {
        try write(Data("source payload".utf8), path: "Resources/document")
        let original = try SigningResolutionSession.sourceFingerprint(in: app)
        let copy = root.appendingPathComponent("Working.app")
        try FileManager.default.copyItem(at: app, to: copy)
        XCTAssertEqual(original, try SigningResolutionSession.sourceFingerprint(in: copy))
        try Data("changed bytes!".utf8).write(to: copy.appendingPathComponent("Resources/document"))
        XCTAssertNotEqual(original, try SigningResolutionSession.sourceFingerprint(in: copy))
        try Data(contentsOf: app.appendingPathComponent("Resources/document")).write(to: copy.appendingPathComponent("Resources/document"))
        var executable = try Data(contentsOf: copy.appendingPathComponent("Fixture")); executable[executable.count - 1] ^= 1
        try executable.write(to: copy.appendingPathComponent("Fixture"))
        XCTAssertNotEqual(original, try SigningResolutionSession.sourceFingerprint(in: copy))
        XCTAssertEqual(original, try SigningResolutionSession.sourceFingerprint(in: app), "The source artifact must stay unchanged.")
    }

    func testPathsEmptyDirectoriesAndFileLengthsAreUnambiguouslyFramed() throws {
        let empty = try SigningResolutionSession.sourceFingerprint(in: app)
        let directory = app.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let withDirectory = try SigningResolutionSession.sourceFingerprint(in: app)
        XCTAssertNotEqual(empty, withDirectory)
        try FileManager.default.removeItem(at: directory)
        try write(Data("bc".utf8), path: "a")
        let first = try SigningResolutionSession.sourceFingerprint(in: app)
        try FileManager.default.removeItem(at: app.appendingPathComponent("a"))
        try write(Data("c".utf8), path: "ab")
        XCTAssertNotEqual(first, try SigningResolutionSession.sourceFingerprint(in: app))
        let renamed = app.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: app.appendingPathComponent("ab"), to: renamed)
        XCTAssertNotEqual(first, try SigningResolutionSession.sourceFingerprint(in: app))
    }

    func testFingerprintRejectsLinkedInputsAndPartialEnumerationBudgets() throws {
        XCTAssertThrowsError(try SigningResolutionSession.sourceFingerprint(in: app, maximumEntries: 0))
        XCTAssertThrowsError(try SigningResolutionSession.sourceFingerprint(in: app, maximumBytes: 1))
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        XCTAssertThrowsError(try SigningResolutionSession.sourceFingerprint(in: alias))
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("linked-resource"), withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertThrowsError(try SigningResolutionSession.sourceFingerprint(in: app))
    }

    func testFingerprintRejectsCancellationBeforeReadingTheTree() async throws {
        let bundle = try XCTUnwrap(app)
        let worker = Task.detached { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try SigningResolutionSession.sourceFingerprint(in: bundle)
        }
        let outcome = await worker.result
        switch outcome {
        case .success: XCTFail("Cancelled hashing was accepted.")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }

    func testDeclaredOptionalPointWithoutReferencesHasPositiveReadOnlyRemovalEvidence() throws {
        _ = try extensionBundle()
        let before = try SigningResolutionSession.sourceFingerprint(in: app)
        XCTAssertTrue(try OptionalExtensionPolicy.canRemove("PlugIns/Share.appex", in: app))
        XCTAssertEqual(before, try SigningResolutionSession.sourceFingerprint(in: app), "Review itself may not mutate the library tree.")
    }

    func testUnknownOrMissingExtensionPointIsNotAssumedOptional() throws {
        _ = try extensionBundle("Required", point: "com.apple.networkextension.packet-tunnel")
        _ = try extensionBundle("Unknown", point: nil)
        XCTAssertFalse(try OptionalExtensionPolicy.canRemove("PlugIns/Required.appex", in: app))
        XCTAssertFalse(try OptionalExtensionPolicy.canRemove("PlugIns/Unknown.appex", in: app))
        XCTAssertFalse(try OptionalExtensionPolicy.canRemove("../Share.appex", in: app))
        XCTAssertFalse(try OptionalExtensionPolicy.canRemove("Watch/Share.app", in: app))
    }

    func testNestedAppsOrRetainedReferencesPreventOptionalRemoval() throws {
        let child = try extensionBundle()
        let nested = child.appendingPathComponent("Embedded.app")
        try SigningRegressionFixture.bundle(at: nested, identifier: "com.example.app.embedded")
        XCTAssertFalse(try OptionalExtensionPolicy.canRemove("PlugIns/Share.appex", in: app))
        try FileManager.default.removeItem(at: nested)
        var dictionary = try XCTUnwrap(SignatureVerifier.readInfo(at: app))
        dictionary["RetainedExtensionReference"] = "com.example.app.share"
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertFalse(try OptionalExtensionPolicy.canRemove("PlugIns/Share.appex", in: app))
    }

    func testBinaryAndUTF16ReferencesAcrossReadChunksCannotBeSilentlyDiscarded() throws {
        _ = try extensionBundle()
        let reference = "com.example.app.share"
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
            let payload = Data(repeating: 0x20, count: 1024 * 1024 - 5) + (try XCTUnwrap(reference.data(using: encoding)))
            try write(payload, path: "Reference.dat")
            XCTAssertFalse(try OptionalExtensionPolicy.canRemove("PlugIns/Share.appex", in: app))
        }
    }

    func testEveryRemovalIsValidatedBeforeAnyBundleIsDeleted() throws {
        let safe = try extensionBundle(), required = try extensionBundle("Required", point: "com.apple.intents-service")
        let before = try SigningResolutionSession.sourceFingerprint(in: app)
        XCTAssertThrowsError(try NestedBundleAudit.removeUncoveredBundles(in: app, profilePattern: "TESTTEAM00.com.example.app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: safe.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: required.path))
        XCTAssertEqual(before, try SigningResolutionSession.sourceFingerprint(in: app))
    }

    func testSavedRemovalToggleWithoutUsableAssetsCannotMutateAnApp() throws {
        _ = try extensionBundle()
        var options = Options.defaultOptions; options.removeAppExtensions = true
        let before = try SigningResolutionSession.sourceFingerprint(in: app)
        XCTAssertThrowsError(try SigningResolutionSession.prepare(bundle: app, options: options, inventory: [],
            preferredIdentity: nil, deviceUDID: nil, authorization: nil, originalRequirements: nil))
        XCTAssertEqual(before, try SigningResolutionSession.sourceFingerprint(in: app))
        XCTAssertFalse(Options.defaultOptions.autoRemoveUnsupportedExtensions)
        XCTAssertFalse(Options.defaultOptions.removeAppExtensions)
    }

    func testRequiredCapabilitiesAreCapturedBeforeBinarySurgeryAndCannotBeReducedByCustomPlist() throws {
        try write(SigningRegressionFixture.machO(entitlements: ["aps-environment": "production"]), path: "Fixture")
        let original = try SigningResolutionSession.requirements(in: app, options: .defaultOptions)
        XCTAssertEqual(original["."]?["aps-environment"] as? String, "production")
        let custom = root.appendingPathComponent("custom.plist")
        try SigningRegressionFixture.plist(["aps-environment": "development"]).write(to: custom)
        var options = Options.defaultOptions; options.appEntitlementsFile = custom
        XCTAssertThrowsError(try SigningResolutionSession.requirements(in: app, options: options))
        XCTAssertEqual(original["."]?["aps-environment"] as? String, "production")
    }
}
