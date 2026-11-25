import XCTest
@testable import VexSign

final class FixtureSlotRecordTests: XCTestCase {
    private let ota = InstallMethodReport(method: .server, readiness: .ready)
    private let signed = DirectInstallVerification(bundlePath: "/fixture.app", hasSignatureDirectory: true,
                                                  hasSignedExecutable: true, unsignedNestedBundles: [])

    func testRemovalPlanRefusedWithoutReinstallPathOrSignedCopy() {
        let packet = FixtureSlotPacket(kind: .backup, bundle: "org.example.test", profile: "digest", marker: UUID(), challenge: nil)
        let challenge = UUID()
        var record = FixtureSlotRecord(copyID: "copy", backup: packet, phase: .ready, challenge: challenge)
        let guest = InstallMethodReport(method: .liveContainer, readiness: .ready)
        XCTAssertThrowsError(try record.planRemoval(route: guest, verification: signed))
        let unsigned = DirectInstallVerification(bundlePath: "/fixture.app", hasSignatureDirectory: false,
                                                  hasSignedExecutable: false, unsignedNestedBundles: [])
        XCTAssertThrowsError(try record.planRemoval(route: ota, verification: unsigned))
        XCTAssertEqual(record.phase, .ready)
        XCTAssertEqual(record.challenge, challenge)
    }

    func testStandaloneRouteAdmission() {
        for method in [InstallMethodKind.liveContainer, .export, .trollstore] {
            XCTAssertNotNil(FixtureSlotRecord.reinstallBlocker(.init(method: method, readiness: .ready)))
        }
        for method in [InstallMethodKind.server, .idevice] {
            XCTAssertNil(FixtureSlotRecord.reinstallBlocker(.init(method: method, readiness: .ready)))
            for readiness in [InstallReadiness.missing("reason"), .unavailable("reason"), .unknown("reason")] {
                XCTAssertEqual(FixtureSlotRecord.reinstallBlocker(.init(method: method, readiness: readiness)), "reason")
            }
        }
    }

    func testCancelledPlanKeepsBackupButRejectsStaleReplies() throws {
        let packet = FixtureSlotPacket(kind: .backup, bundle: "org.example.test", profile: "digest", marker: UUID(), challenge: nil)
        var record = FixtureSlotRecord(copyID: "fixture", backup: packet, phase: .removalPlanned, challenge: UUID())
        let stale = packet.with(.restored, challenge: record.challenge)
        try record.cancelUnsubmittedPlan()
        XCTAssertEqual(record.backup, packet)
        XCTAssertNotEqual(record.challenge, stale.challenge)
        XCTAssertEqual(record.phase, .rehearsal)
        XCTAssertThrowsError(try record.accept(stale))
        try record.accept(packet.with(.rehearsed, challenge: record.challenge))
        try record.planRemoval(route: ota, verification: signed)
        try record.beginReinstall()
        XCTAssertThrowsError(try record.cancelUnsubmittedPlan())
        try record.acknowledgeSubmission()
        XCTAssertThrowsError(try record.cancelUnsubmittedPlan())
    }

    func testOrphanListingRequiresPersistedLockIdentities() throws {
        let packet = FixtureSlotPacket(kind: .backup, bundle: "org.example.fixture", profile: "digest", marker: UUID(), challenge: nil)
        var row = FixtureSlotRecord(copyID: "anchor", backup: packet, phase: .removalPlanned, challenge: UUID())
        XCTAssertNil(row.recoveryEntry)
        row.anchorUUID = "anchor-lock"
        XCTAssertEqual(row.recoveryEntry?.uuid, "anchor-lock")
        row.activeCopyID = "replacement"
        XCTAssertNil(row.recoveryEntry)
        row.activeUUID = "replacement-lock"
        let reopened = try JSONDecoder().decode(FixtureSlotRecord.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(reopened.recoveryEntry?.activeUUID, "replacement-lock")
        XCTAssertEqual(reopened.recoveryEntry?.id, "anchor")
    }

    func testRebindPreservesMarkerAndInvalidatesOldRestoreReply() throws {
        let old = FixtureSlotPacket(kind: .backup, bundle: "org.example.fixture", profile: "old", marker: UUID(), challenge: nil)
        var record = FixtureSlotRecord(copyID: "original", backup: old, phase: .removalPlanned, challenge: UUID(), signingTeam: "TEAM1")
        let now = Date(timeIntervalSince1970: 100)
        let stale = old.with(.restored, challenge: record.challenge)
        func binding(team: String = "TEAM1", bundle: String = "org.example.fixture", expiry: Date = .distantFuture) -> FixtureSlotBinding {
            .init(copy: "replacement", bundle: bundle, profile: "new", team: team, expiry: expiry)
        }
        for denied in [binding(team: "TEAM2"), binding(bundle: "different.app"), binding(expiry: now)] {
            XCTAssertThrowsError(try record.rebind(to: denied, previousTeam: "TEAM1", now: now))
            XCTAssertEqual(record.backup, old)
            XCTAssertEqual(record.challenge, stale.challenge)
        }
        try record.rebind(to: binding(), previousTeam: "TEAM1", now: now)
        var reopened = try JSONDecoder().decode(FixtureSlotRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(reopened.copyID, "original")
        XCTAssertEqual(reopened.activeCopyID, "replacement")
        XCTAssertEqual(reopened.backup.marker, old.marker)
        XCTAssertThrowsError(try reopened.accept(stale))
        try reopened.accept(reopened.backup.with(.restored, challenge: reopened.challenge))
        XCTAssertEqual(reopened.phase, .restored)
    }

    func testInterruptedAndSubmittedAttemptsRequireExplicitRearm() throws {
        let backup = FixtureSlotPacket(kind: .backup, bundle: "org.example.test", profile: "digest", marker: UUID(), challenge: nil)
        var state = FixtureSlotRecord(copyID: "fixture", backup: backup, phase: .removalPlanned, challenge: UUID())
        try state.beginReinstall()
        state = try JSONDecoder().decode(FixtureSlotRecord.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.phase, .reinstallUncertain)
        XCTAssertThrowsError(try state.beginReinstall())
        try state.acknowledgeSubmission()
        XCTAssertThrowsError(try state.beginReinstall())
        let lateReply = backup.with(.restored, challenge: state.challenge)
        try state.allowManualRetry()
        XCTAssertThrowsError(try state.accept(lateReply))
        try state.beginReinstall()
        try state.accept(backup.with(.restored, challenge: state.challenge))
        XCTAssertEqual(state.phase, .restored)
    }

    func testRehearsalCannotBeReplayedAsRestore() throws {
        let backup = FixtureSlotPacket(kind: .backup, bundle: "org.example.test", profile: "test digest", marker: UUID(), challenge: nil)
        var state = FixtureSlotRecord(copyID: "fixture", backup: backup, phase: .rehearsal, challenge: UUID())
        XCTAssertThrowsError(try state.planRemoval(route: ota, verification: signed))
        let reply = backup.with(.rehearsed, challenge: state.challenge)
        try state.accept(reply)
        try state.planRemoval(route: ota, verification: signed)
        XCTAssertThrowsError(try state.planRemoval(route: ota, verification: signed))
        XCTAssertThrowsError(try state.accept(reply))
        let restored = backup.with(.restored, challenge: state.challenge)
        var reopened = try JSONDecoder().decode(FixtureSlotRecord.self, from: JSONEncoder().encode(state))
        try reopened.accept(restored)
        XCTAssertEqual(reopened.phase, .restored)
        XCTAssertThrowsError(try reopened.accept(restored))
    }
}
