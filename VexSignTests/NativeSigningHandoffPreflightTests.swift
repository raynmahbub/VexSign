import Foundation
import XCTest
import NativeSigning
@testable import VexSign

@MainActor
final class NativeSigningHandoffPreflightTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let team = "ABCDE12345"
    private let bundle = "com.example.fixture"
    private let device = "0000ABCD-0011223344556677"
    private let profileUUID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!

    private func identity(
        teamIdentifier: String? = nil,
        phase: NativeSigningIdentityPhase = .certificateRecorded
    ) -> NativeSigningManager.SigningIdentity {
        .init(id: UUID(), identityID: UUID(), teamIdentifier: teamIdentifier ?? team, phase: phase,
              publicKeyHash: "key", csrHash: "csr", certificateHash: "certificate",
              certificateExpiresAt: now.addingTimeInterval(3600))
    }

    private func profile() -> Certificate {
        Certificate(
            AppIDName: "Fixture", ApplicationIdentifierPrefix: [team],
            CreationDate: now.addingTimeInterval(-60), Platform: ["iOS"], IsXcodeManaged: true,
            DeveloperCertificates: [Data([1])], derEncodedProfile: nil, PPQCheck: false,
            Entitlements: [
                "application-identifier": AnyCodable(team + "." + bundle),
                "com.apple.developer.team-identifier": AnyCodable(team),
                "get-task-allow": AnyCodable(true),
                "keychain-access-groups": AnyCodable([team + ".*"]),
            ],
            ExpirationDate: now.addingTimeInterval(3600), Name: "Fixture",
            ProvisionsAllDevices: false, ProvisionedDevices: [device], TeamIdentifier: [team],
            TeamName: "Fixture", TimeToLive: 7, UUID: profileUUID.uuidString, Version: 1
        )
    }

    private func validate(_ profile: Certificate, identity: NativeSigningManager.SigningIdentity? = nil) throws {
        try NativeSigningHandoffPreflight.validate(profile, profileUUID: profileUUID,
            expiresAt: now.addingTimeInterval(3600), teamIdentifier: team,
            identity: identity ?? self.identity(), bundleIdentifier: bundle,
            deviceIdentifier: device, now: now)
    }

    func testExactAuthenticatedTargetPasses() throws {
        try validate(profile())
    }

    func testTargetAndIdentityDriftAreRejectedBeforeImport() {
        var wrongTeam = profile(); wrongTeam.TeamIdentifier = ["OTHER12345"]
        var wrongDevices = profile(); wrongDevices.ProvisionedDevices = ["00008030-001234567890ABCDEF"]
        var allDevices = profile(); allDevices.ProvisionsAllDevices = true
        var wrongBundle = profile()
        wrongBundle.Entitlements?["application-identifier"] = AnyCodable(team + ".com.example.other")
        var missingCertificate = profile(); missingCertificate.DeveloperCertificates = []
        var wrongExpiry = profile(); wrongExpiry.ExpirationDate = now.addingTimeInterval(7200)
        for candidate in [wrongTeam, wrongDevices, allDevices, wrongBundle, missingCertificate, wrongExpiry] {
            XCTAssertThrowsError(try validate(candidate))
        }
        XCTAssertThrowsError(try validate(profile(), identity: identity(teamIdentifier: "OTHER12345")))
        XCTAssertThrowsError(try validate(profile(), identity: identity(phase: .prepared)))
    }

    func testUnsupportedEntitlementsAndMalformedMetadataAreRejected() {
        var debuggingDisabled = profile()
        debuggingDisabled.Entitlements?["get-task-allow"] = AnyCodable(false)
        var wrongGroups = profile()
        wrongGroups.Entitlements?["keychain-access-groups"] = AnyCodable(["OTHER12345.*"])
        var wrongUUID = profile(); wrongUUID.UUID = UUID().uuidString
        var expired = profile(); expired.ExpirationDate = now
        var future = profile(); future.CreationDate = now.addingTimeInterval(1)
        var wrongPlatform = profile(); wrongPlatform.Platform = ["macOS"]
        for candidate in [debuggingDisabled, wrongGroups, wrongUUID, expired, future, wrongPlatform] {
            XCTAssertThrowsError(try validate(candidate))
        }
    }

    // MARK: - Transaction lifecycle

    private enum FixtureError: LocalizedError {
        case profileExport
        case certificateImport

        var errorDescription: String? {
            switch self {
            case .profileExport: "fixture profile export failed"
            case .certificateImport: "fixture certificate import failed"
            }
        }
    }

    private func request() -> NativeSigningHandoffCoordinator.Request {
        .init(profileUUID: profileUUID, expiresAt: now.addingTimeInterval(3600),
              teamIdentifier: team, identity: identity(), bundleIdentifier: bundle,
              deviceIdentifier: device)
    }

    private func encodedProfile() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        // Only CertificateReader's extraction path is exercised here. NativeSigning's
        // separate CMS tests authenticate synthetic CMS before this app-side preflight.
        var bytes = Data([0x30, 0x03, 0x02, 0x01, 0x00])
        bytes.append(try encoder.encode(profile()))
        bytes.append(Data([0x00, 0x01, 0x02]))
        return bytes
    }

    private func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func coordinator(root: URL) -> NativeSigningHandoffCoordinator {
        NativeSigningHandoffCoordinator(temporaryDirectory: root,
            generatePassword: { "fixture-password-not-a-secret" }, now: { self.now })
    }

    private func recordedTask(profileUUID: UUID) throws -> UnifiedTask {
        try XCTUnwrap((UnifiedTaskCenter.shared.tasks + UnifiedTaskCenter.shared.history)
            .first { $0.subjectID == profileUUID.uuidString })
    }

    private func assertScratchRemoved(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(remaining, [], file: file, line: line)
    }

    func testSuccessfulHandoffUsesExactBytesProtectedFilesAndCleansScratch() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let profileData = try encodedProfile()
        let identityData = Data("fixture-p12-bytes".utf8)
        let request = request()
        var profileExports = 0, identityExports = 0, imports = 0

        try await coordinator(root: root).run(request: request, exportProfile: {
            profileExports += 1
            return profileData
        }, backendIsCurrent: { true }, exportIdentity: { password in
            identityExports += 1
            XCTAssertEqual(password, "fixture-password-not-a-secret")
            return identityData
        }, importCertificate: { p12URL, provisionURL, password, name in
            imports += 1
            XCTAssertEqual(password, "fixture-password-not-a-secret")
            XCTAssertEqual(name, "Apple ID " + String(request.identity.identityID.uuidString.prefix(8)))
            XCTAssertEqual(try Data(contentsOf: p12URL), identityData)
            XCTAssertEqual(try Data(contentsOf: provisionURL), profileData)
            for url in [p12URL, provisionURL] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
            let directory = p12URL.deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        })

        XCTAssertEqual(profileExports, 1)
        XCTAssertEqual(identityExports, 1)
        XCTAssertEqual(imports, 1)
        try assertScratchRemoved(root)
        let task = try recordedTask(profileUUID: profileUUID)
        XCTAssertEqual(task.kind, .export)
        XCTAssertEqual(task.phase, .completed)
        XCTAssertEqual(task.progress, 1)
        XCTAssertEqual(task.stageHistory.map(\.phase),
            [.queued, .downloading, .extracting, .importing, .completed])
    }

    func testProfileFailureDoesNotConsumeKeyGrantAndCleansScratch() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        var identityExports = 0, imports = 0

        do {
            try await coordinator(root: root).run(request: request(), exportProfile: {
                throw FixtureError.profileExport
            }, backendIsCurrent: { true }, exportIdentity: { _ in
                identityExports += 1
                return Data([1])
            }, importCertificate: { _, _, _, _ in
                imports += 1
            })
            XCTFail("The profile failure must escape")
        } catch FixtureError.profileExport {
            // Expected: no identity export or import is authorized after this failure.
        }

        XCTAssertEqual(identityExports, 0)
        XCTAssertEqual(imports, 0)
        try assertScratchRemoved(root)
        let task = try recordedTask(profileUUID: profileUUID)
        XCTAssertEqual(task.phase, .failed)
        XCTAssertEqual(task.failureStage, .downloading)
        XCTAssertEqual(task.errorText, FixtureError.profileExport.localizedDescription)
    }

    func testImportFailureIsReportedAtImportAndCleansBothFiles() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let profileData = try encodedProfile()
        var imports = 0

        do {
            try await coordinator(root: root).run(request: request(), exportProfile: {
                profileData
            }, backendIsCurrent: { true }, exportIdentity: { _ in
                Data([0x50, 0x31, 0x32])
            }, importCertificate: { p12URL, provisionURL, _, _ in
                imports += 1
                XCTAssertTrue(FileManager.default.fileExists(atPath: p12URL.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: provisionURL.path))
                throw FixtureError.certificateImport
            })
            XCTFail("The import failure must escape")
        } catch FixtureError.certificateImport {
            // Expected: a failed callback is not a certificate-import success.
        }

        XCTAssertEqual(imports, 1)
        try assertScratchRemoved(root)
        let task = try recordedTask(profileUUID: profileUUID)
        XCTAssertEqual(task.phase, .failed)
        XCTAssertEqual(task.failureStage, .importing)
        XCTAssertEqual(task.errorText, FixtureError.certificateImport.localizedDescription)
    }

    func testCancellationAfterIdentityExportSkipsImportAndCleansScratch() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let profileData = try encodedProfile()
        var identityExports = 0, imports = 0

        do {
            try await coordinator(root: root).run(request: request(), exportProfile: {
                profileData
            }, backendIsCurrent: { true }, exportIdentity: { _ in
                identityExports += 1
                throw CancellationError()
            }, importCertificate: { _, _, _, _ in
                imports += 1
            })
            XCTFail("Cancellation must escape")
        } catch is CancellationError {
            // Expected: cancellation is terminal but is not reported as a failure.
        }

        XCTAssertEqual(identityExports, 1)
        XCTAssertEqual(imports, 0)
        try assertScratchRemoved(root)
        let task = try recordedTask(profileUUID: profileUUID)
        XCTAssertEqual(task.phase, .cancelled)
        XCTAssertNil(task.failureStage)
        XCTAssertNil(task.errorText)
    }

    func testPreCancelledHandoffDoesNotStartExportOrCreateFiles() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        var profileExports = 0, identityExports = 0, imports = 0
        let operation = Task { @MainActor in
            try await self.coordinator(root: root).run(request: self.request(), exportProfile: {
                profileExports += 1
                return Data([1])
            }, backendIsCurrent: { true }, exportIdentity: { _ in
                identityExports += 1
                return Data([1])
            }, importCertificate: { _, _, _, _ in
                imports += 1
            })
        }
        operation.cancel()
        do {
            try await operation.value
            XCTFail("Cancellation must escape")
        } catch is CancellationError {
            // Expected: the initial checkpoint runs before any protected scratch work.
        }

        XCTAssertEqual(profileExports, 0)
        XCTAssertEqual(identityExports, 0)
        XCTAssertEqual(imports, 0)
        try assertScratchRemoved(root)
        let task = try recordedTask(profileUUID: profileUUID)
        XCTAssertEqual(task.phase, .cancelled)
    }
}
