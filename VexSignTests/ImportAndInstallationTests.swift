import XCTest
import ZIPFoundation
@testable import VexSign

final class ImportAndInstallationTests: XCTestCase {
    func testRealIPAWithExplicitPayloadDirectoryEntries() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root.appendingPathComponent("input/Payload/Test.app"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        try Data("fixture".utf8).write(to: input.appendingPathComponent("Payload/Test.app/Info.plist"))
        let ipa = root.appendingPathComponent("Test.ipa")
        do {
            let archive = try Archive(url: ipa, accessMode: .create)
            for path in ["Payload/", "Payload/Test.app/", "Payload/Test.app/Info.plist"] {
                try archive.addEntry(with: path, relativeTo: input)
            }
        }
        XCTAssertNoThrow(try ArchiveSafetyValidator.validate(ipa, destination: root.appendingPathComponent("output", isDirectory: true)))
    }

    func testArchiveRejectsEmbeddedSymlinkEscape() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDestination(relativePath: "escape/outside", root: root))
        for path in ["/Payload/", "../escape", "Payload/../escape", "C:/escape", "", "./Payload"] {
            XCTAssertThrowsError(try ArchiveSafetyValidator.validateDestination(relativePath: path, root: root))
        }
    }

    func testArchiveDestinationAcceptsPayloadDirectoryAndFiles() throws {
        let root = FileManager.default.temporaryDirectory
        for path in ["Payload/", "Payload/Test.app/", "Payload/Test.app/Info.plist"] {
            XCTAssertNoThrow(try ArchiveSafetyValidator.validateDestination(relativePath: path, root: root))
        }
    }

    func testArchiveDestinationRejectsEscapesAndSiblingPrefixes() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vexsign-work")
        for path in ["../outside", "../vexsign-work-other/file"] {
            XCTAssertThrowsError(try ArchiveSafetyValidator.validateDestination(relativePath: path, root: root))
        }
    }

    func testArchiveDestinationAcceptsSymlinkedTemporaryRoot() throws {
        let manager = FileManager.default
        let workspace = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: workspace) }
        let real = workspace.appendingPathComponent("real")
        let alias = workspace.appendingPathComponent("alias")
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDestination(relativePath: "Payload/", root: alias))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDestination(relativePath: "../outside", root: alias))
    }

    func testTaskRecoveryUsesFailureStageBeforeTaskKind() {
        XCTAssertEqual(TaskRecoveryGuide.resolve(kind: .download, failureStage: .signing), .signing)
        XCTAssertEqual(TaskRecoveryGuide.resolve(kind: .update, failureStage: .installing), .installation)
        XCTAssertEqual(TaskRecoveryGuide.resolve(kind: .sign, failureStage: .extracting), .archive)
        XCTAssertEqual(TaskRecoveryGuide.resolve(kind: .install, failureStage: .downloading), .download)
    }

    func testTaskRecoveryFallsBackWithoutGuessingUpdateFailure() {
        XCTAssertEqual(TaskRecoveryGuide.resolve(kind: .update, failureStage: nil), .general)
        XCTAssertEqual(TaskRecoveryGuide.resolve(kind: .export, failureStage: nil), .general)
        XCTAssertEqual(TaskRecoveryGuide.resolve(kind: .importIPA, failureStage: nil), .archive)
        XCTAssertEqual(TaskRecoveryGuide.resolve(kind: .sign, failureStage: nil), .signing)
    }

    func testSideStoreHandoffPreservesHostedQueryExactly() throws {
        let original = "https://example.com/app.ipa?token=a%2Bb&name=Test%20App&redirect=https%3A%2F%2Fexample.com%2Fdone"
        let link = try XCTUnwrap(CompanionHandoffLink.sideStoreInstall(original))
        let components = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "sidestore")
        XCTAssertEqual(components.host, "install")
        XCTAssertEqual(components.queryItems?.count, 1)
        XCTAssertEqual(components.queryItems?.first?.value, original)
    }

    func testSideStoreHandoffRejectsUnsafeInputs() {
        for input in ["", "http://example.com/app.ipa", "file:///tmp/app.ipa", "sidestore://install", "https://user:secret@example.com/app.ipa", "https://example.com/app.ipa#fragment", "https://example.com/app\n.ipa"] {
            XCTAssertNil(CompanionHandoffLink.sideStoreInstall(input), input)
        }
        XCTAssertNotNil(CompanionHandoffLink.sideStoreInstall("  https://example.com/app.ipa  "))
    }

    func testSettingsSearchCoversEachRouteExactlyOnce() {
        let entries = SettingsSearchIndex.entries
        XCTAssertEqual(Set(entries.map(\.id)), Set(SettingsSearchRoute.allCases))
        XCTAssertEqual(entries.count, SettingsSearchRoute.allCases.count)
    }

    func testSettingsSearchMatchesAllTermsAndCompanionKeywords() throws {
        let companion = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == .companionSigning })
        XCTAssertTrue(SettingsSearchIndex.matches(companion, query: " APPLE  login "))
        XCTAssertFalse(SettingsSearchIndex.matches(companion, query: "apple firmware"))
        let appearance = try XCTUnwrap(SettingsSearchIndex.entries.first { $0.id == .appearance })
        XCTAssertTrue(SettingsSearchIndex.matches(appearance, query: "liquid glass"))
    }

    func testCompanionURLValidationExplainsRejectedInput() {
        XCTAssertEqual(CompanionHandoffLink.issue(for: " "), .empty)
        XCTAssertEqual(CompanionHandoffLink.issue(for: "http://example.com/app.ipa"), .requiresHTTPS)
        XCTAssertEqual(CompanionHandoffLink.issue(for: "https://user:password@example.com/app.ipa"), .credentials)
        XCTAssertEqual(CompanionHandoffLink.issue(for: "https://example.com/app.ipa#section"), .fragment)
        XCTAssertEqual(CompanionHandoffLink.issue(for: "https://example.com/app name.ipa"), .malformed)
        XCTAssertNil(CompanionHandoffLink.issue(for: "https://example.com/app%20name.ipa"))
    }

    func testCompanionDestinationSummaryNeverIncludesQueryTokens() {
        XCTAssertEqual(CompanionHandoffLink.destinationHost(for: "https://example.com/private/app.ipa?token=secret"), "example.com")
        XCTAssertNil(CompanionHandoffLink.destinationHost(for: "https://user:password@example.com/app.ipa"))
    }

    func testCompanionIntegrityRequiresComputedMatchingHashWhenRequested() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(CompanionIPAIntegrity.evaluate(expected: "", actual: nil), .notRequested)
        XCTAssertTrue(CompanionIPAIntegrity.notRequested.allowsSharing)
        XCTAssertEqual(CompanionIPAIntegrity.evaluate(expected: hash, actual: nil), .needsFingerprint)
        XCTAssertFalse(CompanionIPAIntegrity.needsFingerprint.allowsSharing)
        XCTAssertEqual(CompanionIPAIntegrity.evaluate(expected: "SHA256:" + hash.uppercased(), actual: hash), .matches)
        XCTAssertTrue(CompanionIPAIntegrity.matches.allowsSharing)
        XCTAssertEqual(CompanionIPAIntegrity.evaluate(expected: hash, actual: String(repeating: "b", count: 64)), .mismatch)
        XCTAssertFalse(CompanionIPAIntegrity.mismatch.allowsSharing)
    }

    func testCompanionIntegrityRejectsMalformedExpectedHashes() {
        for value in ["sha256:", "abc", String(repeating: "g", count: 64), String(repeating: "a", count: 63), String(repeating: "a", count: 65)] {
            XCTAssertEqual(CompanionIPAIntegrity.evaluate(expected: value, actual: nil), .invalidExpectedHash)
        }
        XCTAssertFalse(CompanionIPAIntegrity.invalidExpectedHash.allowsSharing)
    }

    func testCompanionStagerCopiesBytesWithoutChangingSource() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("Test.ipa")
        let contents = Data(repeating: 0xab, count: (1 << 20) + 17)
        try contents.write(to: source)
        let destination = try CompanionIPAStager.copy(source, temporaryRoot: root)
        XCTAssertNotEqual(source, destination)
        XCTAssertEqual(try Data(contentsOf: destination), contents)
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    func testCompanionStagerHonorsCancellationBeforeCreatingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let operation = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CompanionIPAStager.copy(root.appendingPathComponent("missing.ipa"), temporaryRoot: root)
        }
        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
    }

    func testTaskHistorySearchMatchesEveryTermAndFailureStage() {
        let task = UnifiedTask(id: "task", kind: .update, title: "Example App", phase: .failed)
        task.failureStage = .signing
        task.errorText = "Profile expired"
        XCTAssertEqual(TaskHistoryQuery.results([task], query: "EXAMPLE expired", sort: .latest).count, 1)
        XCTAssertTrue(TaskHistoryQuery.results([task], query: "example network", sort: .latest).isEmpty)
        XCTAssertEqual(TaskHistoryQuery.results([task], query: "  ", sort: .latest).count, 1)
    }

    func testTaskHistorySortIsStableAndRemovesDuplicateIDs() {
        let first = UnifiedTask(id: "a", kind: .download, title: "Zebra")
        let second = UnifiedTask(id: "b", kind: .download, title: "Alpha")
        first.updatedAt = Date(timeIntervalSince1970: 10)
        second.updatedAt = Date(timeIntervalSince1970: 20)
        let tasks = [first, second, first]
        XCTAssertEqual(TaskHistoryQuery.results(tasks, query: "", sort: .latest).map(\.id), ["b", "a"])
        XCTAssertEqual(TaskHistoryQuery.results(tasks, query: "", sort: .oldest).map(\.id), ["a", "b"])
        XCTAssertEqual(TaskHistoryQuery.results(tasks, query: "", sort: .name).map(\.id), ["b", "a"])
    }

    func testCertificateInputReaderRejectsOversizeAndNonFiles() throws {
        let file = try temporaryFile(Data(repeating: 0x41, count: 33))
        XCTAssertThrowsError(try CertificateInputReader.read(file, maximumBytes: 32))
        XCTAssertThrowsError(try CertificateInputReader.read(FileManager.default.temporaryDirectory))
        XCTAssertThrowsError(try CertificateInputReader.read(file, maximumBytes: 0))
        XCTAssertEqual(try CertificateInputReader.read(file, maximumBytes: 33).count, 33)
    }

    func testTruncatedPKCS12InputsFailWithoutNativeRevocationCheck() throws {
        let profile = try temporaryFile(profileData())
        let samples: [[UInt8]] = [[0x30], [0x30, 0x82, 0xff, 0xff], [0x30, 0x03, 0x02, 0x01, 0x03]]
        for bytes in samples {
            let key = try temporaryFile(Data(bytes))
            XCTAssertFalse(FR.checkPasswordForCertificate(for: key, with: "", using: profile))
        }
    }

    private func profileData() throws -> Data {
        // Older valid profiles do not have DER-Encoded-Profile.
        let profile: [String: Any] = [
            "AppIDName": "Test App", "CreationDate": Date(timeIntervalSince1970: 0),
            "Platform": ["iOS"], "ExpirationDate": Date(timeIntervalSince1970: 2_000_000_000),
            "Name": "Test Profile", "TeamIdentifier": ["TESTTEAM"], "TeamName": "Test Team",
            "TimeToLive": 365, "UUID": "test-profile", "Version": 1
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testProfileReaderIgnoresBinaryCMSTrailer() throws {
        var envelope = Data([0x30, 0x82, 0xff, 0x00])
        envelope.append(try profileData())
        envelope.append(Data([0xff, 0xfe, 0x00, 0x30]))
        let certificate = CertificateReader(try temporaryFile(envelope)).decoded
        XCTAssertEqual(certificate?.Name, "Test Profile")
        XCTAssertNil(certificate?.derEncodedProfile)
    }

    func testProfileReaderRejectsTruncatedAndEmptyFiles() throws {
        for data in [Data(), Data("<?xml version=\"1.0\"?><plist><dict>".utf8)] {
            XCTAssertNil(CertificateReader(try temporaryFile(data)).decoded)
        }
        XCTAssertNil(CertificateReader(URL(fileURLWithPath: "/missing.mobileprovision")).decoded)
    }

    func testMalformedP12DoesNotCrashPasswordValidation() throws {
        let profile = try temporaryFile(profileData())
        for data in [Data(), Data("not a PKCS12 identity".utf8)] {
            let key = try temporaryFile(data)
            XCTAssertFalse(FR.checkPasswordForCertificate(for: key, with: "wrong", using: profile))
        }
    }

    func testFailedImportReportsErrorOnMainThread() throws {
        let completion = expectation(description: "Import reports failure")
        let key = try temporaryFile(Data("bad P12".utf8))
        let profile = try temporaryFile(profileData())
        FR.handleCertificateFiles(p12URL: key, provisionURL: profile, p12Password: "") { error in
            XCTAssertNotNil(error)
            XCTAssertTrue(Thread.isMainThread)
            completion.fulfill()
        }
        wait(for: [completion], timeout: 5)
    }

    func testInstallLinkPreservesNestedManifestQuery() throws {
        let manifest = "https://example.com/genPlist?name=Test%20App&fetchurl=http%3A%2F%2F127.0.0.1%3A5000%2Fapp.ipa"
        let link = ServerInstaller.installLink(manifest: manifest)
        let components = try XCTUnwrap(URLComponents(string: link))
        XCTAssertEqual(components.scheme, "itms-services")
        XCTAssertEqual(components.queryItems?.count, 2)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "url" })?.value, manifest)
    }

    func testSSLHostnameValidation() {
        XCTAssertEqual(ServerInstaller.normalizedHostname("*.example.com\n"), "local.example.com")
        XCTAssertEqual(ServerInstaller.normalizedHostname("localhost.example.com"), "localhost.example.com")
        for invalid in ["", "null", "https://example.com", "example.com/path", "bad host", "example.com:443", "example.com?query", "user@example.com"] {
            XCTAssertNil(ServerInstaller.normalizedHostname(invalid), invalid)
        }
    }

    func testOpenIsOnlyAvailableForSuccessfulInstalls() {
        let success = InstallQueue.InstallOutcome.succeeded
        XCTAssertTrue(success.canOpenApp(isExport: false, identifier: "com.example.app"))
        XCTAssertFalse(success.canOpenApp(isExport: true, identifier: "com.example.app"))
        XCTAssertFalse(success.canOpenApp(isExport: false, identifier: nil))
        XCTAssertFalse(success.canOpenApp(isExport: false, identifier: ""))
        for outcome in [InstallQueue.InstallOutcome.pending, .skipped, .failed("Install failed")] {
            XCTAssertFalse(outcome.canOpenApp(isExport: false, identifier: "com.example.app"))
        }
    }

    func testHomeIsAvailableInDefaultNavigation() {
        // The default five-tab order is Library → Home →
        // App Store → Downloads → Settings; Home is always present and
        // never hideable, along with the other primary tabs.
        XCTAssertEqual(TabEnum.defaultTabs, [.library, .home, .appStore, .downloads, .settings])
        XCTAssertTrue(TabEnum.defaultTabs.contains(.home))
        XCTAssertFalse(TabBarPreferences.hideableTabs.contains(.home))
        XCTAssertFalse(TabBarPreferences.hideableTabs.contains(.settings))
    }
}
