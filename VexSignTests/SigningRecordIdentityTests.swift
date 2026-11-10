//
//  SigningRecordIdentityTests.swift
//  VexSignTests
//
//  Which recorded signing runs describe one library copy.
//
//  A run is recorded against the copy it was started from; the copy it produced is a different
//  record. Library details mixed the two up: a signed copy showed nothing about the run that
//  produced it, and after a re-sign that failed it showed "Failed" as its signing result - on a
//  copy that the failed run never touched.
//

import Foundation
import XCTest
@testable import VexSign

final class SigningRecordIdentityTests: XCTestCase {
	private typealias Entry = SigningRecordIdentity.Entry<String>

	/// A run named `name`, started from `source`. `artifact` is set only when it completed.
	private func run(
		_ name: String,
		from source: String?,
		produced artifact: String? = nil,
		at time: TimeInterval,
		completed: Bool? = nil
	) -> Entry {
		Entry(
			record: name,
			sourceID: source,
			artifactID: artifact,
			updatedAt: Date(timeIntervalSince1970: time),
			completed: completed ?? (artifact != nil)
		)
	}

	// MARK: - The reported case

	func testAFailedReSignIsNotTheResultOfTheCopyItStartedFrom() {
		let records = [
			run("first sign", from: "import", produced: "signed", at: 100),
			run("failed re-sign", from: "signed", at: 200)
		]

		let selection = SigningRecordIdentity.select(copyID: "signed", from: records)

		XCTAssertEqual(selection.produced, "first sign", "The copy's own result is the run that produced it")
		XCTAssertEqual(selection.unfinishedAttempt, "failed re-sign")
		XCTAssertEqual(selection.latestStarted, "failed re-sign")
	}

	func testAFreshlySignedCopyReportsTheRunThatProducedIt() {
		let records = [run("first sign", from: "import", produced: "signed", at: 100)]

		let selection = SigningRecordIdentity.select(copyID: "signed", from: records)

		XCTAssertEqual(selection.produced, "first sign")
		XCTAssertNil(selection.latestStarted, "Nothing was ever started from the signed copy")
		XCTAssertNil(selection.unfinishedAttempt)
	}

	// MARK: - The source side

	func testAnImportedCopyReportsTheNewestRunStartedFromIt() {
		let records = [
			run("old failure", from: "import", at: 100),
			run("first sign", from: "import", produced: "signed", at: 200)
		]

		let selection = SigningRecordIdentity.select(copyID: "import", from: records)

		XCTAssertNil(selection.produced, "Signing never produces an imported copy")
		XCTAssertEqual(selection.latestStarted, "first sign")
		XCTAssertNil(selection.unfinishedAttempt, "The newest run completed, so the older failure is superseded")
	}

	func testARunStillInFlightIsAnUnfinishedAttempt() {
		let records = [
			run("first sign", from: "import", produced: "signed", at: 100),
			run("running re-sign", from: "signed", at: 200, completed: false)
		]

		let selection = SigningRecordIdentity.select(copyID: "signed", from: records)

		XCTAssertEqual(selection.produced, "first sign")
		XCTAssertEqual(selection.unfinishedAttempt, "running re-sign")
	}

	func testOnlyTheNewestAttemptIsReported() {
		let records = [
			run("first sign", from: "import", produced: "signed", at: 100),
			run("failure 1", from: "signed", at: 200),
			run("failure 2", from: "signed", at: 300),
			run("cancelled", from: "signed", at: 250)
		]

		let selection = SigningRecordIdentity.select(copyID: "signed", from: records)

		XCTAssertEqual(selection.unfinishedAttempt, "failure 2")
	}

	func testALaterSuccessSupersedesAnEarlierFailure() {
		// The copy was kept after a re-sign through the signing sheet produced a second copy.
		let records = [
			run("first sign", from: "import", produced: "signed", at: 100),
			run("failure", from: "signed", at: 200),
			run("second sign", from: "signed", produced: "signed-2", at: 300)
		]

		let kept = SigningRecordIdentity.select(copyID: "signed", from: records)
		XCTAssertEqual(kept.produced, "first sign")
		XCTAssertEqual(kept.latestStarted, "second sign")
		XCTAssertNil(kept.unfinishedAttempt, "The failure is no longer the latest thing that happened")

		let replacement = SigningRecordIdentity.select(copyID: "signed-2", from: records)
		XCTAssertEqual(replacement.produced, "second sign")
		XCTAssertNil(replacement.latestStarted)
	}

	// MARK: - Records that must not match

	func testARecordOfAnotherCopyIsNeverReported() {
		let records = [
			run("other sign", from: "other-import", produced: "other-signed", at: 100),
			run("other failure", from: "other-signed", at: 200)
		]

		let selection = SigningRecordIdentity.select(copyID: "signed", from: records)

		XCTAssertNil(selection.produced)
		XCTAssertNil(selection.latestStarted)
		XCTAssertNil(selection.unfinishedAttempt)
	}

	func testACopyWithoutAnIdentifierMatchesNothing() {
		let records = [
			run("anonymous", from: nil, at: 100),
			run("empty", from: "", produced: "", at: 200)
		]

		for copyID in [nil, ""] as [String?] {
			let selection = SigningRecordIdentity.select(copyID: copyID, from: records)
			XCTAssertNil(selection.produced)
			XCTAssertNil(selection.latestStarted)
			XCTAssertNil(selection.unfinishedAttempt)
		}
	}

	func testARunThatDidNotCompleteCannotClaimACopy() {
		// Defensive: an artifact identifier on a record that never completed is not evidence.
		let records = [run("half-written", from: "import", produced: "signed", at: 100, completed: false)]

		let selection = SigningRecordIdentity.select(copyID: "signed", from: records)

		XCTAssertNil(selection.produced)
	}

	func testTheNewestProducingRecordWinsWhenHistoryHoldsMoreThanOne() {
		let records = [
			run("older", from: "import", produced: "signed", at: 100),
			run("newer", from: "import", produced: "signed", at: 200)
		]

		XCTAssertEqual(SigningRecordIdentity.select(copyID: "signed", from: records).produced, "newer")
	}

	func testNoRecordsMeansNothingIsClaimed() {
		let selection = SigningRecordIdentity.select(copyID: "signed", from: [Entry]())

		XCTAssertNil(selection.produced)
		XCTAssertNil(selection.latestStarted)
		XCTAssertNil(selection.unfinishedAttempt)
	}
}
