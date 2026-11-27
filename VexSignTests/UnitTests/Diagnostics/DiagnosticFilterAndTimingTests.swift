import Foundation
import XCTest
@testable import VexSign

final class DiagnosticFilterAndTimingTests: XCTestCase {
    func testFilterMatchesCategoriesDatesAndOperationIDs() {
        let now = Date()
        let event = DiagnosticEvent.make(
            code: DiagnosticEventCode.signFailed,
            severity: .error,
            category: .signing,
            operationID: "op-abcdef12",
            timestamp: now,
            userMessage: "Signing failed."
        )
        XCTAssertTrue(DiagnosticExportFilter(categories: [.signing]).matches(event))
        XCTAssertFalse(DiagnosticExportFilter(categories: [.network]).matches(event))
        XCTAssertTrue(DiagnosticExportFilter(operationID: "op-abcdef12").matches(event))
        XCTAssertFalse(DiagnosticExportFilter(operationID: "op-other").matches(event))
        XCTAssertTrue(DiagnosticExportFilter(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1)).matches(event))
        XCTAssertFalse(DiagnosticExportFilter(from: now.addingTimeInterval(1)).matches(event))
    }

    func testOutcomeFilterUsesCorrelationIDAndFinishDate() {
        let now = Date()
        let outcome = OperationOutcomeRecord(
            correlationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            operation: "install",
            stage: "install",
            status: .unconfirmed,
            startedAt: now.addingTimeInterval(-5),
            finishedAt: now
        )
        XCTAssertTrue(DiagnosticExportFilter(operationID: outcome.correlationID).matches(outcome))
        XCTAssertTrue(DiagnosticExportFilter(categories: [.installation]).matches(outcome))
        XCTAssertFalse(DiagnosticExportFilter(categories: [.signing]).matches(outcome))
        XCTAssertFalse(DiagnosticExportFilter(from: now.addingTimeInterval(1)).matches(outcome))
    }

    func testStopwatchProducesObservedDurationAndSafeEvent() {
        let stopwatch = DiagnosticStopwatch("signingTest", category: .signing, operationID: "op-abcdef12")
        let elapsed = stopwatch.finish()
        XCTAssertGreaterThanOrEqual(elapsed, 0)
        let event = stopwatch.event(elapsedMilliseconds: elapsed)
        XCTAssertEqual(event.code, DiagnosticEventCode.performanceMeasurement)
        XCTAssertEqual(event.operationID, "op-abcdef12")
        XCTAssertEqual(event.metadata["elapsedMs"], String(format: "%.1f", elapsed))
    }

    func testFilterDescriptorContainsOnlySafeFields() {
        let descriptor = DiagnosticExportFilter(
            categories: [.signing],
            operationID: "op-abcdef12"
        ).jsonObject
        XCTAssertEqual(descriptor["categories"] as? [String], ["signing"])
        XCTAssertEqual(descriptor["operationID"] as? String, "op-abcdef12")
        XCTAssertNil(descriptor["userMessage"])
    }
}
