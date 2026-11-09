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

    func testHashStopsAtChunkCheckpoint() throws {
        let url = directory.appendingPathComponent("large.ipa")
        try Data(repeating: 42, count: 3 * 1024 * 1024).write(to: url)
        var checks = 0
        XCTAssertThrowsError(try FileIntegrity.sha256(of: url, cancellationCheck: {
            checks += 1
            if checks == 3 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 3)
    }

    func testCancelledVerificationDoesNotReturnMismatch() throws {
        let url = try writeFile(named: "cancelled.ipa", contents: "payload")
        XCTAssertThrowsError(try DownloadIntegrity.verify(fileAt: url, expectation: empty, cancellationCheck: {
            throw CancellationError()
        })) { XCTAssertTrue($0 is CancellationError) }
    }

	private var empty = DownloadIntegrity.Expectation()

	func testPackageTransferSizeLimitHandlesDeclaredAndStreamingSizes() {
		let limit = DownloadIntegrity.maximumPackageBytes
		XCTAssertFalse(DownloadIntegrity.transferExceedsPackageLimit(expectedBytes: limit, receivedBytes: limit))
		XCTAssertTrue(DownloadIntegrity.transferExceedsPackageLimit(expectedBytes: limit + 1, receivedBytes: 0))
		XCTAssertTrue(DownloadIntegrity.transferExceedsPackageLimit(expectedBytes: -1, receivedBytes: limit + 1))
		XCTAssertFalse(DownloadIntegrity.transferExceedsPackageLimit(expectedBytes: -1, receivedBytes: 0))
		XCTAssertTrue(DownloadIntegrity.expectationExceedsPackageLimit(.init(byteCount: limit + 1)))
		XCTAssertFalse(DownloadIntegrity.expectationExceedsPackageLimit(.init()))
	}

	func testTemporaryStagingDirectoryIsCreatedBeforeMove() throws {
		let staging = try DownloadStagingPath.createTemporaryDirectory(label: "UpdateAllTests")
		addTeardownBlock { try FileManager.default.removeItem(at: staging) }
		XCTAssertTrue((try staging.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
		let stagedFile = DownloadStagingPath.destination(in: staging, suggestedFilename: "update.ipa")
		try Data("ipa".utf8).write(to: stagedFile)
		XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFile.path))
	}

	func testStagingFilenameIsSingleComponentAndUnique() {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
		let first = DownloadStagingPath.destination(in: directory, suggestedFilename: "../../Library/app.ipa")
		let second = DownloadStagingPath.destination(in: directory, suggestedFilename: "..\\Library\\app.ipa")
		XCTAssertEqual(first.deletingLastPathComponent(), directory)
		XCTAssertEqual(second.deletingLastPathComponent(), directory)
		XCTAssertNotEqual(first, second)
		XCTAssertTrue(first.lastPathComponent.hasSuffix("-app.ipa"))
		XCTAssertEqual(DownloadStagingPath.safeFilename("../.."), "download.ipa")
	}

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

	func testAutomaticImportRejectsMismatchAndAllowsUnverifiedSource() throws {
		let url = try writeFile(named: "update.ipa", contents: "truncated")
		let mismatch = DownloadIntegrity.automaticImportFailure(
			fileAt: url,
			expectation: DownloadIntegrity.Expectation(byteCount: 100),
			fileName: "update.ipa"
		)
		XCTAssertNotNil(mismatch)
		XCTAssertTrue(mismatch?.contains("Nothing was imported") == true, mismatch ?? "")

		XCTAssertNil(DownloadIntegrity.automaticImportFailure(
			fileAt: url,
			expectation: .init(),
			fileName: "update.ipa"
		), "Sources with no declared size/hash remain supported")
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
