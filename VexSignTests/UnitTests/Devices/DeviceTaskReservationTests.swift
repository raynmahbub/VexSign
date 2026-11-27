//
//  DeviceTaskReservationTests.swift
//  VexSignTests
//
//  Device operations serialize on a subject before a task is created. Without the
//  reservation, two main-actor callers could both observe "no task yet", adopt the
//  same queued task and each submit the same install to iOS.
//

import XCTest
@testable import VexSign

final class DeviceTaskReservationTests: XCTestCase {
    @MainActor
    func testSecondCallerCannotReserveTheSameDeviceSubject() async {
        let reporter = DeviceLifecycleTaskReporter(center: .shared)
        let subject = "test-device-reservation." + UUID().uuidString

        let first = await reporter.beginOnce(
            kind: .deviceSetup, title: "First", subtitle: nil, subjectID: subject
        )
        XCTAssertNotNil(first)
        let second = await reporter.beginOnce(
            kind: .deviceSetup, title: "Second", subtitle: nil, subjectID: subject
        )
        XCTAssertNil(second)

        guard let first else { return }
        await reporter.transition(id: first, to: .completed)
        let third = await reporter.beginOnce(
            kind: .deviceSetup, title: "Third", subtitle: nil, subjectID: subject
        )
        XCTAssertNotNil(third)
        if let third { await reporter.transition(id: third, to: .cancelled) }
    }

    @MainActor
    func testFailedTerminalPhaseAlsoReleasesTheReservation() async {
        let reporter = DeviceLifecycleTaskReporter(center: .shared)
        let subject = "test-device-reservation." + UUID().uuidString
        let taskID = await reporter.beginOnce(
            kind: .install, title: "Install", subtitle: nil, subjectID: subject
        )
        XCTAssertNotNil(taskID)
        guard let taskID else { return }
        await reporter.transition(id: taskID, to: .failed, error: "fixture")
        let retry = await reporter.beginOnce(
            kind: .install, title: "Retry", subtitle: nil, subjectID: subject
        )
        XCTAssertNotNil(retry)
        if let retry { await reporter.transition(id: retry, to: .cancelled) }
    }
}
