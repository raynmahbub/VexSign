//
//  TaskSigningTraceCompatibilityTests.swift
//  VexSignTests
//
//  A task record outlives the build that wrote it. These tests pin the two properties that make
//  that safe: the on-disk stage names never move, and a name this build does not know costs one
//  stage instead of the entire history file.
//

import XCTest
@testable import VexSign

final class TaskSigningTraceCompatibilityTests: XCTestCase {
    /// The on-disk form of `SigningStage`. Append only, and never rename: these strings are in
    /// every task record ever written, and `tools/test_task_history_resilience.py` fails if this
    /// list and the enum disagree.
    private let frozenStageNames = [
        "copying", "modifying", "thinning", "injecting", "signing", "verifying", "registering"
    ]

    func testThePersistedStageNamesHaveNotMoved() {
        XCTAssertEqual(SigningStage.allCases.map(\.rawValue), frozenStageNames)
    }

    // MARK: - Lossy trace decoding

    private func trace(_ json: String) throws -> TaskSigningTrace {
        try JSONDecoder().decode(TaskSigningTrace.self, from: Data(json.utf8))
    }

    func testAKnownTraceDecodesUnchanged() throws {
        let decoded = try trace(#"{"stages":["copying","signing","verifying"],"stoppedAt":"verifying","verified":true,"outcome":"completed"}"#)
        XCTAssertEqual(decoded.stages, [.copying, .signing, .verifying])
        XCTAssertEqual(decoded.stoppedAt, .verifying)
        XCTAssertEqual(decoded.verified, true)
        XCTAssertEqual(decoded.outcome, .completed)
    }

    func testAnUnknownStageIsDroppedAndTheRestSurvives() throws {
        // This is what a record written by a newer build looks like to this one.
        let decoded = try trace(#"{"stages":["copying","teleporting","signing"],"stoppedAt":"teleporting","verified":true,"outcome":"completed"}"#)
        XCTAssertEqual(decoded.stages, [.copying, .signing])
        XCTAssertNil(decoded.stoppedAt, "an unreadable stage name is not a stage this build can name")
        XCTAssertEqual(decoded.verified, true)
        XCTAssertEqual(decoded.outcome, .completed)
    }

    func testAnUnknownOutcomeDoesNotFailTheTrace() throws {
        let decoded = try trace(#"{"stages":["signing"],"outcome":"quarantined"}"#)
        XCTAssertEqual(decoded.stages, [.signing])
        XCTAssertNil(decoded.outcome)
        XCTAssertFalse(decoded.isEmpty)
    }

    func testAnEmptyOrMissingTraceIsReadable() throws {
        XCTAssertTrue(try trace("{}").isEmpty)
        XCTAssertNil(try trace(#"{"stages":[]}"#).stoppedAt)
    }

    func testEncodingStillWritesTheStableNames() throws {
        var value = TaskSigningTrace()
        value.record(.copying)
        value.recordVerification()
        value.record(outcome: .completed)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
        XCTAssertEqual(object["stages"] as? [String], ["copying"])
        XCTAssertEqual(object["stoppedAt"] as? String, "copying")
        XCTAssertEqual(object["verified"] as? Bool, true)
        XCTAssertEqual(object["outcome"] as? String, "completed")
    }

    // MARK: - The property that matters

    func testARecordWithAnUnknownStageStillDecodesAsATaskSnapshot() throws {
        // The failure this replaces: the trace was nested inside the snapshot, so its throw took
        // the whole history array with it.
        let json = #"""
        {
          "id": "task-1", "kind": "sign", "title": "Signed Example", "phase": "completed",
          "createdAt": 0, "updatedAt": 0,
          "context": { "signingTrace": { "stages": ["copying", "teleporting"], "outcome": "completed" } }
        }
        """#
        let snapshot = try JSONDecoder().decode(UnifiedTask.Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.title, "Signed Example")
        XCTAssertEqual(snapshot.context?.signing.stages, [.copying])
        XCTAssertEqual(snapshot.context?.signing.outcome, .completed)

        // And the surrounding task still round-trips through the model the UI reads.
        let task = UnifiedTask.from(snapshot)
        XCTAssertEqual(task.title, "Signed Example")
        XCTAssertEqual(task.context?.signing.stages, [.copying])
    }

    func testASnapshotWrittenByThisBuildRoundTripsWithItsTrace() throws {
        let task = UnifiedTask(kind: .sign, title: "Round trip", phase: .signing)
        var context = TaskContext()
        context.recordSigningStage(.copying)
        context.recordSigningStage(.signing)
        context.recordSigningVerification()
        context.recordSigningOutcome(.completed)
        task.context = context

        let data = try JSONEncoder().encode(task.snapshot)
        let decoded = try JSONDecoder().decode(UnifiedTask.Snapshot.self, from: data)
        XCTAssertEqual(decoded.context?.signing.stages, [.copying, .signing])
        XCTAssertEqual(decoded.context?.signing.verified, true)
        XCTAssertEqual(decoded.context?.signing.outcome, .completed)
    }
}
