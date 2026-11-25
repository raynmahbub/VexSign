//
//  AsyncWait.swift
//  VexSignTests
//
//  Two ways to wait in a test, so the timing assumption is written down.
//
//  A fixed sleep before a *positive* assertion is the classic flaky test: it passes on
//  an idle machine and fails on a loaded CI runner. Wait for the condition instead. A
//  *negative* assertion has no event to await, so it uses an explicit settle window —
//  long enough that a stray callback would have run, and named so a reader knows the
//  wait is deliberate rather than a guess.
//

import Foundation
import XCTest

enum AsyncWait {
	/// Polls `condition` until it holds. Fails the calling test after `timeout`.
	///
	/// `message` names what was waited for, so a timeout says which expectation broke.
	static func until(
		_ message: String = "a condition",
		timeout: TimeInterval = 5,
		file: StaticString = #filePath,
		line: UInt = #line,
		_ condition: () -> Bool
	) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if condition() { return }
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		XCTFail("Timed out after \(timeout)s waiting for \(message)", file: file, line: line)
		throw WaitTimeout()
	}

	/// A settle window for an assertion that something must *not* happen.
	static func settle(_ duration: Duration = .milliseconds(300)) async {
		do {
			try await Task.sleep(for: duration)
		} catch {
			// A cancelled test wait is the test ending, not a failure of the code under test.
		}
	}

	struct WaitTimeout: Error {}
}
