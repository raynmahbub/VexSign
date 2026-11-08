import Foundation
import XCTest
import IDeviceSwift
@testable import VexSign

final class RecoveryAndResourceTests: XCTestCase {
    func testRestartPreservesFinishedWorkAndInterruptsActiveWork() throws {
        let signing = UnifiedTask(kind: .sign, title: "Private", phase: .signing)
        signing.context?.artifactID = "stored-copy"
        signing.recoverAfterRestart()
        XCTAssertEqual(signing.phase, .interrupted)
        XCTAssertEqual(signing.failureStage, .signing)
        XCTAssertFalse(signing.move(to: .signing))
        XCTAssertTrue(TaskReceipt.report(for: signing).contains("interrupted-process-exit"))
        XCTAssertEqual(signing.context?.artifactID, "stored-copy")
        let data = try JSONEncoder().encode(signing.snapshot)
        let restored = UnifiedTask.from(try JSONDecoder().decode(UnifiedTask.Snapshot.self, from: data))
        let events = restored.stageHistory
        restored.recoverAfterRestart()
        XCTAssertEqual(restored.stageHistory, events)
        let complete = UnifiedTask(kind: .sign, title: "Done", phase: .completed)
        complete.recoverAfterRestart()
        XCTAssertEqual(complete.phase, .completed)
    }

    func testSharedOwnershipBlocksConflictsButNotOtherApps() throws {
        let registry = AppOperationRegistry()
        var lease: AppOperationRegistry.Lease? = try registry.acquire("signed:one")
        XCTAssertTrue(registry.isBusy("signed:one"))
        XCTAssertThrowsError(try registry.acquire("signed:one"))
        let unrelated = try registry.acquire("signed:two")
        XCTAssertTrue(registry.isBusy("signed:two"))
        XCTAssertNotNil(lease)
        lease = nil
        XCTAssertFalse(registry.isBusy("signed:one"))
        let retry = try registry.acquire("signed:one")
        withExtendedLifetime([unrelated, retry]) {}
    }

    func testWorkerReferenceRetainsLeaseAfterOwnerStops() throws {
        let registry = AppOperationRegistry()
        var owner: AppOperationRegistry.Lease? = try registry.acquire("app")
        var worker = owner
        owner = nil
        XCTAssertThrowsError(try registry.acquire("app"))
        XCTAssertNotNil(worker)
        worker = nil
        XCTAssertFalse(registry.isBusy("app"))
    }

    func testStorageEstimatesSaturateAndRejectInsufficientSpace() {
        XCTAssertEqual(StoragePreflight.required(bytes: Int64.max, copies: 3), Int64.max)
        XCTAssertEqual(StoragePreflight.required(bytes: 100, copies: 2), 200 + StoragePreflight.margin)
        XCTAssertThrowsError(try StoragePreflight.check(bytes: 100, copies: 2,
            at: FileManager.default.temporaryDirectory, available: 100))
        XCTAssertNoThrow(try StoragePreflight.check(bytes: 100, copies: 2,
            at: FileManager.default.temporaryDirectory, available: 200 + StoragePreflight.margin))
    }

    func testUnavailableEvidenceStopsWithinBoundWithoutClaimingInstalled() {
        let zero = Date(timeIntervalSince1970: 0)
        var engine = InstallConfirmation(expectation: .init(bundleIdentifier: "example.app"))
        _ = engine.beginVerifying(at: zero)
        XCTAssertEqual(engine.record(probe: nil, at: zero.addingTimeInterval(29)), .verifying)
        XCTAssertEqual(engine.record(probe: nil, at: zero.addingTimeInterval(30)), .finished(.timedOutVerifying))
        XCTAssertFalse(engine.phase.verdict?.provesInstalled ?? true)
    }

    func testPositiveEvidenceBeforeDeadlineStillCompletes() {
        let zero = Date(timeIntervalSince1970: 0)
        var engine = InstallConfirmation(expectation: .init(bundleIdentifier: "example.app"))
        _ = engine.beginVerifying(at: zero)
        _ = engine.record(probe: nil, at: zero.addingTimeInterval(25))
        XCTAssertEqual(engine.record(probe: InstalledApp(bundleIdentifier: "example.app", isInstalled: true),
            at: zero.addingTimeInterval(29)), .finished(.installed))
    }

    func testPairingMigrationFailuresKeepOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("pairing.plist")
        let destination = root.appendingPathComponent("Private/pairing.plist")
        let bytes = Data("original-private-test-record".utf8)
        try bytes.write(to: legacy)
        for code in [CocoaError.Code.fileWriteNoPermission, .fileWriteOutOfSpace] {
            XCTAssertThrowsError(try PairingFileStorage.migrate(legacy: legacy, destination: destination,
                beforeMove: { _, _ in throw CocoaError(code) }))
            XCTAssertEqual(try Data(contentsOf: legacy), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        try PairingFileStorage.migrate(legacy: legacy, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testBlockedCertificateDestinationNeverDeletesLegacyIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let legacy = root.appendingPathComponent("Documents/Certificates")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let original = legacy.appendingPathComponent("identity.p12")
        try Data("original".utf8).write(to: original)
        let blocked = root.appendingPathComponent("Private")
        try Data("not-a-directory".utf8).write(to: blocked)
        XCTAssertThrowsError(try ProtectedCertificateFiles.migrate(legacy: legacy,
            destination: blocked.appendingPathComponent("Certificates")))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: blocked), Data("not-a-directory".utf8))
    }

    func testPartialCertificateMigrationCanResumeWithoutOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
        let legacy = root.appendingPathComponent("Documents/Certificates")
        let destination = root.appendingPathComponent("Private/Certificates")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("first-key".utf8).write(to: legacy.appendingPathComponent("a.p12"))
        try Data("second-key".utf8).write(to: legacy.appendingPathComponent("b.p12"))
        XCTAssertThrowsError(try ProtectedCertificateFiles.migrate(legacy: legacy, destination: destination,
            beforeMove: { source, _ in if source.lastPathComponent == "b.p12" { throw CocoaError(.fileWriteOutOfSpace) } }))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.p12")), Data("first-key".utf8))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("b.p12")), Data("second-key".utf8))
        try ProtectedCertificateFiles.migrate(legacy: legacy, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("b.p12")), Data("second-key".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }
}
