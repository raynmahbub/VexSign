//
//  DownloadSpeedTrackerTests.swift
//  VexSignTests
//
//  The tracker smooths byte deltas into the rate shown in the download row. It is
//  pure, deterministic and had no coverage — the exact combination that lets a
//  sign error (a negative rate, a rate that never falls after a stall) ship.
//

import XCTest
@testable import VexSign

final class DownloadSpeedTrackerTests: XCTestCase {

	private let start = Date(timeIntervalSince1970: 1_700_000_000)

	func testFirstSampleEstablishesABaselineRatherThanARate() {
		var tracker = DownloadSpeedTracker()
		XCTAssertEqual(tracker.sample(totalBytes: 1_000_000, at: start), 0)
	}

	func testSteadyDownloadRisesTowardsTheInstantaneousRate() {
		var tracker = DownloadSpeedTracker()
		_ = tracker.sample(totalBytes: 0, at: start)
		let rate = tracker.sample(totalBytes: 1_000_000, at: start.addingTimeInterval(1))
		XCTAssertEqual(rate, 1_000_000, "the first real interval is used as-is, not smoothed from zero")
	}

	func testRateIsSmoothedAfterTheFirstInterval() {
		var tracker = DownloadSpeedTracker()
		_ = tracker.sample(totalBytes: 0, at: start)
		_ = tracker.sample(totalBytes: 1_000_000, at: start.addingTimeInterval(1))
		// Next second delivers twice as much: 2 MB/s instantaneous, smoothed at 0.4.
		let smoothed = tracker.sample(totalBytes: 3_000_000, at: start.addingTimeInterval(2))
		XCTAssertEqual(smoothed, 1_400_000)
	}

	func testSamplesCloserTogetherThanTheMinimumIntervalAreIgnored() {
		var tracker = DownloadSpeedTracker()
		_ = tracker.sample(totalBytes: 0, at: start)
		_ = tracker.sample(totalBytes: 1_000_000, at: start.addingTimeInterval(1))
		let before = tracker.current
		let after = tracker.sample(totalBytes: 1_500_000, at: start.addingTimeInterval(1.05))
		XCTAssertEqual(after, before, "a 50 ms tick must not produce a spike")
	}

	func testShrinkingTotalRebasesInsteadOfReadingAsAStall() {
		var tracker = DownloadSpeedTracker()
		_ = tracker.sample(totalBytes: 5_000_000, at: start)
		_ = tracker.sample(totalBytes: 6_000_000, at: start.addingTimeInterval(1))
		let rate = tracker.sample(totalBytes: 2_000_000, at: start.addingTimeInterval(2))
		XCTAssertEqual(rate, tracker.current)
		XCTAssertGreaterThanOrEqual(rate, 0, "a download leaving the list must never produce a negative rate")
		// The rebase means the next byte counts from the new total, not from 6 MB.
		let resumed = tracker.sample(totalBytes: 3_000_000, at: start.addingTimeInterval(3))
		XCTAssertGreaterThan(resumed, 0)
	}

	func testAStallDecaysTheRateInsteadOfFreezingIt() {
		var tracker = DownloadSpeedTracker()
		_ = tracker.sample(totalBytes: 0, at: start)
		_ = tracker.sample(totalBytes: 1_000_000, at: start.addingTimeInterval(1))
		let peak = tracker.current
		var now = start.addingTimeInterval(1)
		for _ in 0 ..< 20 {
			now = now.addingTimeInterval(1)
			_ = tracker.sample(totalBytes: 1_000_000, at: now)
		}
		XCTAssertLessThan(tracker.current, peak)
		XCTAssertEqual(tracker.current, 0, "with no progress nothing should still be shown as moving")
	}

	func testAnAbsurdDeltaIsCappedRatherThanDisplayed() {
		var tracker = DownloadSpeedTracker()
		_ = tracker.sample(totalBytes: 0, at: start)
		let rate = tracker.sample(totalBytes: 500_000_000_000, at: start.addingTimeInterval(0.25))
		XCTAssertLessThanOrEqual(rate, 1_073_741_824, "the row must not show petabytes per second")
	}

	func testResetClearsEverything() {
		var tracker = DownloadSpeedTracker()
		_ = tracker.sample(totalBytes: 0, at: start)
		_ = tracker.sample(totalBytes: 1_000_000, at: start.addingTimeInterval(1))
		tracker.reset()
		XCTAssertEqual(tracker.current, 0)
		XCTAssertEqual(tracker.sample(totalBytes: 9_000_000, at: start.addingTimeInterval(2)), 0,
		               "after a reset the next sample is a new baseline")
	}
}
