//
//  DownloadIntegrityTests.swift
//  VexSignTests
//
//  Tests for a source that publishes a size gets that size enforced before the importer
//  ever sees the file.
//
//  These use real files in a temporary directory, because the thing under test is the comparison
//  against what is on disk — a stub of `FileManager` would test the stub.
//

import Foundation
import XCTest
@testable import VexSign

final class DownloadIntegrityTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("DownloadIntegrityTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let directory {
			try? FileManager.default.removeItem(at: directory)
		}
	}

	@discardableResult
	private func writeFile(named name: String, contents: String) throws -> URL {
		let url = directory.appendingPathComponent(name)
		try Data(contents.utf8).write(to: url)
		return url
	}

	private var empty = DownloadIntegrity.Expectation()

	// MARK: - Nothing declared

	func testEmptyExpectationIsUnverified() throws {
		let url = try writeFile(named: "app.ipa", contents: "payload")
		XCTAssertTrue(empty.isEmpty)
		XCTAssertEqual(DownloadIntegrity.verify(fileAt: url, expectation: empty), .unverified)
	}

	// MARK: - Matching file

	func testSizeMatchIsVerified() throws {
		let url = try writeFile(named: "app.ipa", contents: "payload")
		let expectation = DownloadIntegrity.Expectation(byteCount: 7)

		XCTAssertEqual(DownloadIntegrity.verify(fileAt: url, expectation: expectation), .verified(checks: 1))
	}

	func testSizeAndHashMatchIsVerifiedWithTwoChecks() throws {
		let url = try writeFile(named: "app.ipa", contents: "payload")
		let hash = try XCTUnwrap(FileIntegrity.sha256(of: url))
		let expectation = DownloadIntegrity.Expectation(byteCount: 7, sha256: hash)

		XCTAssertEqual(DownloadIntegrity.verify(fileAt: url, expectation: expectation), .verified(checks: 2))
	}

	func testPublishedHashIsNormalisedBeforeComparing() throws {
		let url = try writeFile(named: "app.ipa", contents: "payload")
		let hash = try XCTUnwrap(FileIntegrity.sha256(of: url))

		// A source that publishes "SHA256:ABCD…" in upper case must still match.
		let expectation = DownloadIntegrity.Expectation(sha256: "SHA256:" + hash.uppercased())
		XCTAssertEqual(expectation.sha256, hash)
		XCTAssertEqual(DownloadIntegrity.verify(fileAt: url, expectation: expectation), .verified(checks: 1))
	}

	// MARK: - Truncated download

	func testSizeMismatchFailsWithBothNumbers() throws {
		let url = try writeFile(named: "app.ipa", contents: "pay") // truncated
		let expectation = DownloadIntegrity.Expectation(byteCount: 7)

		let verdict = DownloadIntegrity.verify(fileAt: url, expectation: expectation)
		XCTAssertEqual(verdict, .mismatch([.size(expected: 7, actual: 3)]))

		guard case .mismatch(let failures) = verdict else { return XCTFail("expected a mismatch") }
		let message = DownloadIntegrity.describe(failures, fileName: "app.ipa")
		XCTAssertTrue(message.contains("app.ipa"), message)
		XCTAssertTrue(message.contains("3"), message)
		XCTAssertTrue(message.contains("7"), message)
		XCTAssertTrue(message.contains("Nothing was imported"), message)
	}

	func testMissingFileReportsAnUnreadableSize() throws {
		let url = directory.appendingPathComponent("gone.ipa")
		let expectation = DownloadIntegrity.Expectation(byteCount: 7)

		let verdict = DownloadIntegrity.verify(fileAt: url, expectation: expectation)
		XCTAssertEqual(verdict, .mismatch([.size(expected: 7, actual: nil)]))

		guard case .mismatch(let failures) = verdict else { return XCTFail("expected a mismatch") }
		let message = DownloadIntegrity.describe(failures, fileName: "gone.ipa")
		XCTAssertTrue(message.contains("could not be read"), message)
	}

	// MARK: - Hash

	func testHashMismatchBlocksEvenWhenTheSizeMatches() throws {
		let url = try writeFile(named: "app.ipa", contents: "payload")
		let expectation = DownloadIntegrity.Expectation(byteCount: 7, sha256: String(repeating: "a", count: 64))

		guard case .mismatch(let failures) = DownloadIntegrity.verify(fileAt: url, expectation: expectation) else {
			return XCTFail("expected a mismatch")
		}
		XCTAssertEqual(failures.count, 1)
		guard case .hash(let expected, let actual) = failures[0] else {
			return XCTFail("expected a hash failure, got \(failures[0])")
		}
		XCTAssertEqual(expected, String(repeating: "a", count: 64))
		XCTAssertNotNil(actual)
		XCTAssertNotEqual(actual, expected)

		let message = DownloadIntegrity.describe(failures, fileName: "app.ipa")
		XCTAssertTrue(message.contains("SHA-256"), message)
		// The published hash is printed so it can be compared with the source by hand.
		XCTAssertTrue(message.contains(expected), message)
	}

	func testBothChecksCanFailAtOnce() throws {
		let url = try writeFile(named: "app.ipa", contents: "pay")
		let expectation = DownloadIntegrity.Expectation(byteCount: 99, sha256: String(repeating: "b", count: 64))

		guard case .mismatch(let failures) = DownloadIntegrity.verify(fileAt: url, expectation: expectation) else {
			return XCTFail("expected a mismatch")
		}
		XCTAssertEqual(failures.count, 2)

		let message = DownloadIntegrity.describe(failures, fileName: "app.ipa")
		// Two problems, two lines, plus the closing hint.
		XCTAssertEqual(message.components(separatedBy: "\n\n").count, 2, message)
	}

	// MARK: - Byte count

	func testByteCountReadsTheFileOnDisk() throws {
		let url = try writeFile(named: "app.ipa", contents: "payload")
		XCTAssertEqual(DownloadIntegrity.byteCount(of: url), 7)
		XCTAssertNil(DownloadIntegrity.byteCount(of: directory.appendingPathComponent("missing.ipa")))
	}
}
