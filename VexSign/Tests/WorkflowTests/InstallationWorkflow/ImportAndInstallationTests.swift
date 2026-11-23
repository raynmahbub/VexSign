import XCTest
import ZIPFoundation
import IDeviceSwift
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

    // MARK: - Duplicate output paths

    /// Two entries resolving to one output path. `IPAExtractor` rejects these while writing, but
    /// the ZIP spec does not forbid them and a reader that lets the last entry win would extract a
    /// different file than the one that was inspected — so the rule has to live in the validator
    /// every backend shares, not in one backend.
    func testArchiveRejectsTwoEntriesClaimingTheSameOutputPath() {
        var claimed = Set<String>()
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDuplicate("Payload/Test.app/Info.plist", in: &claimed))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDuplicate("Payload/Test.app/Info.plist", in: &claimed)) { error in
            guard case ArchiveSafetyValidator.ValidationError.duplicateEntry = error else {
                return XCTFail("Expected duplicateEntry, got \(error)")
            }
        }
        XCTAssertEqual(claimed.count, 1)
    }

    func testArchiveRejectsDuplicatesThatDifferOnlyInCase() {
        // APFS on iOS is case-insensitive, so these are one file on the destination even though
        // they are two entries in the archive.
        var claimed = Set<String>()
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDuplicate("Payload/Test.app/Info.plist", in: &claimed))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDuplicate("Payload/Test.app/info.plist", in: &claimed))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDuplicate("payload/test.app/INFO.PLIST", in: &claimed))
    }

    func testADirectoryEntryAndAFileEntrySharingAPathConflict() {
        // The trailing separator is not part of an entry's identity: a bundle cannot be both a
        // directory and a file at the same path.
        var claimed = Set<String>()
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDuplicate("Payload/Test.app/", in: &claimed))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDuplicate("Payload/Test.app", in: &claimed))
    }

    // MARK: - Unicode normalization

    /// APFS stores names normalized and compares them that way, so one archive can carry
    /// `Café.app` twice — precomposed (NFC) and decomposed (NFD) — and both land on one file.
    /// Comparing the raw strings sees two distinct paths; the filesystem sees one.
    func testArchiveRejectsDuplicatesThatDifferOnlyInUnicodeNormalization() {
        let precomposed = "Payload/Caf\u{00E9}.app/Info.plist"       // é as one scalar
        let decomposed = "Payload/Cafe\u{0301}.app/Info.plist"       // e + combining acute
        // `String` compares by canonical equivalence, so these are *equal* as Swift
        // strings even though their UTF-8 differs. That is exactly why the fixture
        // cannot rely on `!=`: the distinctness has to be measured at the byte level,
        // which is also what the archive carries and what the filesystem stores.
        XCTAssertNotEqual(
            Array(precomposed.utf8), Array(decomposed.utf8),
            "the fixture has to differ in its bytes"
        )

        var claimed = Set<String>()
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDuplicate(precomposed, in: &claimed))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDuplicate(decomposed, in: &claimed)) { error in
            guard case ArchiveSafetyValidator.ValidationError.duplicateEntry = error else {
                return XCTFail("Expected duplicateEntry, got \(error)")
            }
        }
        XCTAssertEqual(claimed.count, 1)
    }

    func testNormalizationAndCaseFoldingCombineIntoOneIdentity() {
        // Neither difference alone is enough to collide, and both together must.
        var claimed = Set<String>()
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDuplicate("Payload/Caf\u{00E9}.app", in: &claimed))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDuplicate("payload/CAFE\u{0301}.APP", in: &claimed))
    }

    func testIdentityKeyIsStableAcrossEquivalentSpellings() throws {
        let a = try XCTUnwrap(ArchiveSafetyValidator.identityKey("Payload/Caf\u{00E9}.app/"))
        let b = try XCTUnwrap(ArchiveSafetyValidator.identityKey("payload/cafe\u{0301}.app"))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "payload/caf\u{00E9}.app")
        XCTAssertNil(ArchiveSafetyValidator.identityKey(""))
        XCTAssertNil(ArchiveSafetyValidator.identityKey("/"))
    }

    func testDistinctUnicodeNamesAreStillDistinctPaths() {
        // Normalization must not over-merge: different letters stay different files.
        var claimed = Set<String>()
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDuplicate("Payload/Caf\u{00E9}.app", in: &claimed))
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDuplicate("Payload/Cafe.app", in: &claimed))
        XCTAssertEqual(claimed.count, 2)
    }

    // MARK: - File/directory conflicts

    /// `Payload/App.app/Info.plist` makes `Payload/App.app` a directory. A second entry that
    /// declares the same path a *file* cannot be honoured on a real filesystem, and which one
    /// wins depends on the extractor. It is rejected rather than resolved by extraction order.
    func testAFileEntryThatClaimsAnImpliedDirectoryConflicts() {
        var implied = ArchiveSafetyValidator.ImpliedDirectories()
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateImpliedDirectories(
            relativePath: "Payload/App.app/Info.plist", isDirectory: false, in: &implied))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateImpliedDirectories(
            relativePath: "Payload/App.app", isDirectory: false, in: &implied)) { error in
            guard case ArchiveSafetyValidator.ValidationError.pathTypeConflict = error else {
                return XCTFail("Expected pathTypeConflict, got \(error)")
            }
        }
    }

    func testTheConflictIsCaughtWhicheverEntryComesFirst() {
        var implied = ArchiveSafetyValidator.ImpliedDirectories()
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateImpliedDirectories(
            relativePath: "Payload/App.app", isDirectory: false, in: &implied))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateImpliedDirectories(
            relativePath: "Payload/App.app/Info.plist", isDirectory: false, in: &implied))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateImpliedDirectories(
            relativePath: "Payload/App.app/", isDirectory: true, in: &implied))
    }

    func testAnOrdinaryIpaDirectoryLayoutHasNoTypeConflict() {
        var implied = ArchiveSafetyValidator.ImpliedDirectories()
        for (path, isDirectory) in [
            ("Payload/", true),
            ("Payload/Test.app/", true),
            ("Payload/Test.app/Info.plist", false),
            ("Payload/Test.app/Frameworks/", true),
            ("Payload/Test.app/Frameworks/Lib.framework/Lib", false)
        ] {
            XCTAssertNoThrow(try ArchiveSafetyValidator.validateImpliedDirectories(
                relativePath: path, isDirectory: isDirectory, in: &implied), path)
        }
    }

    func testADeeplyNestedPathIsAcceptedAndStillContained() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let deep = (0..<40).map { "d\($0)" }.joined(separator: "/") + "/file.txt"
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDestination(relativePath: deep, root: root))
        // Deep nesting must not become an escape: a traversal anywhere in the path is refused,
        // however many legitimate components precede it.
        let prefix = (0..<40).map { "d\($0)" }.joined(separator: "/")
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDestination(
            relativePath: prefix + "/../../escape", root: root))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDestination(
            relativePath: prefix + "/./file.txt", root: root))
    }

    func testDistinctPathsSiblingsAndNestedDirectoriesAreNotDuplicates() {
        var claimed = Set<String>()
        // A real IPA's explicit directory entries plus its files, in archive order.
        for path in ["Payload/", "Payload/Test.app/", "Payload/Test.app/Info.plist",
                     "Payload/Test.app/Test", "Payload/Test.app/Frameworks/",
                     "Payload/Test.app/Frameworks/Lib.framework/",
                     "Payload/Test.app/Frameworks/Lib.framework/Lib"] {
            XCTAssertNoThrow(try ArchiveSafetyValidator.validateDuplicate(path, in: &claimed), path)
        }
        XCTAssertEqual(claimed.count, 7)
        // A sibling that shares a prefix is a different path, not a duplicate.
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDuplicate("Payload/Test.app/Info.plist.bak", in: &claimed))
        XCTAssertNoThrow(try ArchiveSafetyValidator.validateDuplicate("Payload/Test2.app/Info.plist", in: &claimed))
    }

    func testAnEmptyOutputPathIsRejectedRatherThanClaimed() {
        var claimed = Set<String>()
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDuplicate("", in: &claimed))
        XCTAssertThrowsError(try ArchiveSafetyValidator.validateDuplicate("/", in: &claimed))
        XCTAssertTrue(claimed.isEmpty, "A rejected entry must not consume an output path")
    }

    func testDuplicateEntryErrorSaysWhichPathConflicted() throws {
        let error = ArchiveSafetyValidator.ValidationError.duplicateEntry("Payload/Test.app/Info.plist")
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("Payload/Test.app/Info.plist"),
                      "The report has to name the conflicting path: \(message)")
        XCTAssertFalse(message.isEmpty)
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
        let task = queryRecord(id: "task", kind: .update, title: "Example App", phase: .failed,
            updatedAt: Date(), failureStage: .signing, errorText: "Profile expired")
        XCTAssertEqual(TaskHistoryQuery.results([task], query: "EXAMPLE expired", sort: .latest).count, 1)
        XCTAssertTrue(TaskHistoryQuery.results([task], query: "example network", sort: .latest).isEmpty)
        XCTAssertEqual(TaskHistoryQuery.results([task], query: "  ", sort: .latest).count, 1)
    }

    func testTaskHistorySortIsStableAndRemovesDuplicateIDs() {
        let first = queryRecord(id: "a", kind: .download, title: "Zebra", updatedAt: Date(timeIntervalSince1970: 10))
        let second = queryRecord(id: "b", kind: .download, title: "Alpha", updatedAt: Date(timeIntervalSince1970: 20))
        let tasks = [first, second, first]
        XCTAssertEqual(TaskHistoryQuery.results(tasks, query: "", sort: .latest).map(\.id), ["b", "a"])
        XCTAssertEqual(TaskHistoryQuery.results(tasks, query: "", sort: .oldest).map(\.id), ["a", "b"])
        XCTAssertEqual(TaskHistoryQuery.results(tasks, query: "", sort: .name).map(\.id), ["b", "a"])
    }

    private func queryRecord(
        id: String,
        kind: UnifiedTaskKind,
        title: String,
        phase: UnifiedTaskPhase = .queued,
        updatedAt: Date,
        failureStage: UnifiedTaskPhase? = nil,
        errorText: String? = nil
    ) -> TaskRecord {
        let queryText = [title, "", kind.title, phase.title, failureStage?.title ?? "", errorText ?? ""]
            .joined(separator: " ")
        return TaskRecord(id: id, kind: kind, title: title, subtitle: nil, phase: phase, progress: 0,
            failureStage: failureStage, errorText: errorText, createdAt: updatedAt, updatedAt: updatedAt,
            subjectID: nil, artifactID: nil, signingTrace: nil, displayPhaseTitle: phase.title,
            queryText: queryText, receipt: "", outcome: "", outcomeUnknown: false, canRetry: false)
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
            XCTAssertFalse(CertificateManagementService.validateSigningPair(for: key, with: "", using: profile))
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

    func testProfileReaderRejectsXMLHiddenInAMalformedCMSEnvelope() throws {
        var envelope = Data([0x30, 0x82, 0xff, 0x00])
        envelope.append(try profileData())
        envelope.append(Data([0xff, 0xfe, 0x00, 0x30]))
        let certificate = CertificateReader(try temporaryFile(envelope)).decoded
        XCTAssertNil(certificate, "Finding an XML substring inside unrelated bytes does not authenticate provisioning.")
    }

    func testProfileReaderRejectsTruncatedAndEmptyFiles() throws {
        for data in [Data(), Data("<?xml version=\"1.0\"?><plist><dict>".utf8)] {
            XCTAssertNil(CertificateReader(try temporaryFile(data)).decoded)
        }
        XCTAssertNil(CertificateReader(URL(fileURLWithPath: "/missing.mobileprovision")).decoded)
    }

    func testMalformedP12DoesNotCrashPairValidation() throws {
        let profile = try temporaryFile(profileData())
        for data in [Data(), Data("not a PKCS12 identity".utf8)] {
            let key = try temporaryFile(data)
            XCTAssertFalse(CertificateManagementService.validateSigningPair(for: key, with: "wrong", using: profile))
        }
    }

    func testCertificateImportRequiresTheProfileToNameTheActualP12Leaf() throws {
        var profile = try SigningRegressionFixture.profile()
        let identity = try XCTUnwrap(SigningIdentity(SigningRegressionFixture.certificateDER))
        profile.DeveloperCertificates = [Data("another leaf".utf8)]
        XCTAssertFalse(CertificateManagementService.profileAuthorizes(identity, profile: profile))
        profile.DeveloperCertificates = [Data("another leaf".utf8), SigningRegressionFixture.certificateDER]
        XCTAssertTrue(CertificateManagementService.profileAuthorizes(identity, profile: profile))
        profile.DeveloperCertificates = nil
        XCTAssertFalse(CertificateManagementService.profileAuthorizes(identity, profile: profile))
    }

    func testFailedImportReportsErrorOnMainThread() throws {
        let completion = expectation(description: "Import reports failure")
        let key = try temporaryFile(Data("bad P12".utf8))
        let profile = try temporaryFile(profileData())
        CertificateManagementService.importCertificateFiles(p12URL: key, provisionURL: profile, p12Password: "") { error in
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
        for outcome in [InstallQueue.InstallOutcome.pending, .skipped, .guestPrepared, .failed("Install failed")] {
            XCTAssertFalse(outcome.canOpenApp(isExport: false, identifier: "com.example.app"))
        }
    }

    @MainActor
    func testSkipIgnoresStaleTapsAfterAnOutcomeAndAllowsFailureActions() {
        XCTAssertTrue(InstallQueue.canSkip(outcome: .pending, hasFailure: false))
        XCTAssertTrue(InstallQueue.canSkip(outcome: .failed("Install failed"), hasFailure: true))
        XCTAssertFalse(InstallQueue.canSkip(outcome: .succeeded, hasFailure: false))
        XCTAssertFalse(InstallQueue.canSkip(outcome: .skipped, hasFailure: false))
        XCTAssertFalse(InstallQueue.canSkip(outcome: .guestPrepared, hasFailure: false))
        XCTAssertFalse(InstallQueue.canSkip(outcome: nil, hasFailure: false))
    }

    @MainActor
    func testInstallQueueAdvanceSchedulerCancelsStaleAutomaticAdvance() async throws {
        let scheduler = InstallQueueAdvanceScheduler()
        var advances = 0

        scheduler.schedule(after: 0.04) { advances += 100 }
        scheduler.cancel()
        scheduler.schedule(after: 0.02) { advances += 1 }

        // Wait for the event the test is about, not for a duration: a loaded runner can
        // deliver the timer later than any fixed sleep, and 120 ms used to be the guess.
        try await AsyncWait.until("the automatic advance fires") { advances == 1 }
        XCTAssertEqual(advances, 1, "A stale completion timer must not advance a later install.")
    }

    func testHomeIsAvailableInDefaultNavigation() {
        // Home and Settings remain visible so the user can always recover the
        // navigation configuration.
        XCTAssertEqual(TabEnum.defaultTabs, [.home, .appStore, .library, .downloads, .settings])
        XCTAssertTrue(TabEnum.defaultTabs.contains(.home))
        XCTAssertFalse(TabBarPreferences.hideableTabs.contains(.home))
        XCTAssertFalse(TabBarPreferences.hideableTabs.contains(.settings))
    }

    func testServerInstallerManifestNilSafetyAndCapabilityTokens() throws {
        let validApp = LibraryAppRecord(
            id: "signed:1",
            uuid: "uuid-1",
            isSigned: true,
            name: nil,
            version: nil,
            identifier: "com.example.nil_safe",
            originalIdentifier: nil,
            date: nil,
            icon: nil,
            appDescription: nil,
            sortIndex: 0,
            source: nil,
            certificateID: nil,
            bundleURL: nil,
            artifactURL: nil
        )
        let installer = ServerInstaller(
            app: validApp,
            viewModel: InstallerStatusViewModel(isIdevice: false),
            serverMethod: 0,
            localhostOnly: true
        )

        XCTAssertGreaterThanOrEqual(installer.installToken.count, 32)
        XCTAssertTrue(installer.plistEndpoint.path.contains(installer.installToken))
        XCTAssertTrue(installer.payloadEndpoint.path.contains(installer.installToken))
        let pageComponents = try XCTUnwrap(URLComponents(url: installer.pageEndpoint, resolvingAgainstBaseURL: false))
        XCTAssertEqual(pageComponents.queryItems?.first(where: { $0.name == "token" })?.value, installer.installToken)

        let plistData = try installer.buildInstallManifestData()
        XCTAssertFalse(plistData.isEmpty)
        let parsed = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any])
        let items = try XCTUnwrap(parsed["items"] as? [[String: Any]])
        let metadata = try XCTUnwrap(items.first?["metadata"] as? [String: String])
        XCTAssertEqual(metadata["bundle-identifier"], "com.example.nil_safe")
        XCTAssertEqual(metadata["bundle-version"], "1.0")
        XCTAssertEqual(metadata["title"], "com.example.nil_safe")

        let missingBundleIDApp = LibraryAppRecord(
            id: "signed:2",
            uuid: "uuid-2",
            isSigned: true,
            name: "Broken",
            version: "1.0",
            identifier: nil,
            originalIdentifier: nil,
            date: nil,
            icon: nil,
            appDescription: nil,
            sortIndex: 0,
            source: nil,
            certificateID: nil,
            bundleURL: nil,
            artifactURL: nil
        )
        let brokenInstaller = ServerInstaller(
            app: missingBundleIDApp,
            viewModel: InstallerStatusViewModel(isIdevice: false),
            serverMethod: 0,
            localhostOnly: true
        )
        XCTAssertThrowsError(try brokenInstaller.buildInstallManifestData())
    }
}
