import Foundation
import XCTest
import IDeviceSwift
@testable import VexSign

final class WorkflowTraceTests: XCTestCase {
    func testSigningAndInstallationAreIndependentResults() {
        let signing = UnifiedTask(kind: .sign, title: "Private", phase: .signing)
        XCTAssertFalse(signing.move(to: .installing))
        XCTAssertTrue(signing.move(to: .signed))
        XCTAssertTrue(signing.move(to: .completed))
        XCTAssertFalse(signing.move(to: .failed))
        let installation = UnifiedTask(kind: .install, title: "Private", phase: .preparingInstallation)
        for phase in [UnifiedTaskPhase.waitingForIOS, .installing, .verifying, .failed] {
            XCTAssertTrue(installation.move(to: phase))
        }
        XCTAssertEqual(installation.failureStage, .verifying)
        XCTAssertEqual(signing.phase, .completed)
        XCTAssertFalse(installation.move(to: .completed))
    }

    func testImportAndSigningMilestonesAreExplicit() {
        let task = UnifiedTask(kind: .importIPA, title: "App", phase: .importing)
        XCTAssertTrue(task.move(to: .readyToSign))
        XCTAssertTrue(task.move(to: .completed))
        XCTAssertEqual(task.displayPhaseTitle, UnifiedTaskPhase.readyToSign.title)
        XCTAssertEqual(task.stageHistory.map(\.phase), [.importing, .readyToSign, .completed])
    }

    func testRepeatedStageUpdatesDoNotGrowHistoryOrFinishOperation() {
        let task = UnifiedTask(kind: .install, title: "App", phase: .installing)
        for _ in 0..<1000 { XCTAssertTrue(task.move(to: .installing)) }
        XCTAssertEqual(task.stageHistory.count, 1)
        task.progress = 1
        XCTAssertFalse(task.phase.isTerminal)
        XCTAssertTrue(task.move(to: .cancelled))
        XCTAssertFalse(task.move(to: .queued))
    }

    @MainActor
    func testNativeCompletionDoesNotExposeCompletedDuringVerification() {
        let model = InstallerStatusViewModel(status: .completed(.success(())))
        model.installProgress = 1
        model.beginDeviceVerification()
        XCTAssertFalse(model.isCompleted)
        XCTAssertEqual(model.installProgress, 0.99)
        AppInstaller.Outcome.installed.publishConfirmedCompletion(to: model)
        XCTAssertTrue(model.isCompleted)
    }

    func testSnapshotsRoundTripAndOldHistoryStillLoads() throws {
        let task = UnifiedTask(kind: .sign, title: "App", phase: .signing)
        task.context?.appVersion = "1.2.3"
        task.context?.artifactID = "stored-copy"
        task.move(to: .signed)
        task.move(to: .completed)
        let data = try JSONEncoder().encode(task.snapshot)
        let restored = UnifiedTask.from(try JSONDecoder().decode(UnifiedTask.Snapshot.self, from: data))
        XCTAssertEqual(restored.stageHistory, task.stageHistory)
        XCTAssertEqual(restored.context, task.context)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "context")
        legacy.removeValue(forKey: "stageHistory")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        let old = UnifiedTask.from(try JSONDecoder().decode(UnifiedTask.Snapshot.self, from: oldData))
        XCTAssertEqual(old.phase, .completed)
        XCTAssertNil(old.context)
        XCTAssertEqual(old.stageHistory.count, 1)
    }

    func testReportIncludesSafeEvidenceAndOmitsPrivateFields() {
        let task = UnifiedTask(kind: .install, title: "private-app", subtitle: "https://private.invalid", phase: .preparingInstallation, subjectID: "private-subject")
        task.context?.appVersion = "1.2.3"
        task.context?.appBuild = "42"
        task.context?.clientVersion = "8.0 (123)"
        task.context?.sourceCommit = String(repeating: "a", count: 40)
        task.context?.installationMethod = "OTA"
        task.context?.artifactID = "private-artifact"
        task.context?.confirmationReason = "device-confirmed-installed"
        task.move(to: .verifying)
        task.move(to: .completed)
        task.errorText = "password=secret /private/var/key.p12"
        let report = TaskReceipt.report(for: task)
        for value in ["1.2.3", "42", "8.0 (123)", "OTA", "device-confirmed-installed", "Elapsed:"] {
            XCTAssertTrue(report.contains(value))
        }
        for value in ["private-app", "private.invalid", "private-subject", "private-artifact", "secret", "key.p12"] {
            XCTAssertFalse(report.contains(value))
        }
    }

    func testUntrustedReportMetadataCannotSmuggleSecrets() {
        let task = UnifiedTask(kind: .sign, title: "App")
        task.context?.appVersion = "password=secret"
        task.context?.appBuild = "/private/var/key.p12"
        task.context?.sourceCommit = "token=secret"
        task.context?.clientVersion = "password=secret"
        task.context?.installationMethod = "secret"
        task.context?.confirmationReason = "secret"
        task.context?.certificateReference = "secret"
        task.context?.optionsFingerprint = "secret"
        let report = TaskReceipt.report(for: task)
        XCTAssertFalse(report.contains("secret"))
        XCTAssertFalse(report.contains("key.p12"))
        XCTAssertEqual(BuildIdentity.validatedCommit("$(VEXSIGN_SOURCE_COMMIT)"), "unavailable")
    }

    func testCertificateMigrationPreservesManagedIdentityAndCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let legacy = root.appendingPathComponent("Documents/Certificates")
        let destination = root.appendingPathComponent("Private/Certificates")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("identity"), withIntermediateDirectories: true)
        try Data("key-material".utf8).write(to: legacy.appendingPathComponent("identity/test.p12"))
        try ProtectedCertificateFiles.migrate(legacy: legacy, destination: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("identity/test.p12")), Data("key-material".utf8))
        try ProtectedCertificateFiles.migrate(legacy: legacy, destination: destination)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("identity"), withIntermediateDirectories: true)
        try Data("older-key".utf8).write(to: legacy.appendingPathComponent("identity/test.p12"))
        try ProtectedCertificateFiles.migrate(legacy: legacy, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("identity/test.p12")), Data("key-material".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)
    }

    func testPairingMigrationRetainsCredentialsPrivatelyAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("pairingFile.plist")
        let destination = root.appendingPathComponent("Private/pairingFile.plist")
        let contents = Data("test-record".utf8)
        try contents.write(to: legacy)
        try PairingFileStorage.migrate(legacy: legacy, destination: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: destination), contents)
        try PairingFileStorage.migrate(legacy: legacy, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), contents)
        try Data("older-record".utf8).write(to: legacy)
        try PairingFileStorage.migrate(legacy: legacy, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).count, 2)
    }
}
