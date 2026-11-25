//
//  WebManagerTransferLimitsTests.swift
//  VexSignTests
//
//  The Web Manager streams uploads to disk, so `defaultMaxBodySize` never applies to them.
//  These pin the replacement bounds: the per-buffer arithmetic, the free-space preflight,
//  and the upload file's own accounting. Pure — no server, no sockets, no device.
//

import XCTest
@testable import VexSign

final class WebManagerTransferLimitsTests: XCTestCase {

	// MARK: - Per-buffer cap

	func testUploadExactlyAtTheLimitIsAccepted() {
		XCTAssertTrue(WebManagerTransferLimits.accepts(current: 0, incoming: 1024, limit: 1024))
		XCTAssertTrue(WebManagerTransferLimits.accepts(current: 1024, incoming: 0, limit: 1024))
	}

	func testOneByteOverTheLimitIsRefused() {
		XCTAssertFalse(WebManagerTransferLimits.accepts(current: 0, incoming: 1025, limit: 1024))
		XCTAssertFalse(WebManagerTransferLimits.accepts(current: 1024, incoming: 1, limit: 1024))
	}

	func testCumulativeWritesAreCappedNotJustIndividualBuffers() {
		// The point of the check: many small buffers must not add up past the ceiling.
		XCTAssertTrue(WebManagerTransferLimits.accepts(current: 1000, incoming: 24, limit: 1024))
		XCTAssertFalse(WebManagerTransferLimits.accepts(current: 1000, incoming: 25, limit: 1024))
	}

	func testHostileAccumulationCannotOverflow() {
		XCTAssertFalse(WebManagerTransferLimits.accepts(current: Int.max, incoming: Int.max, limit: 1024))
		XCTAssertFalse(WebManagerTransferLimits.accepts(current: 5, incoming: Int.max, limit: 1024))
	}

	func testNonPositiveLimitRefusesEverythingAndHostileSpansAreNoOps() {
		XCTAssertFalse(WebManagerTransferLimits.accepts(current: 0, incoming: 1, limit: 0))
		XCTAssertFalse(WebManagerTransferLimits.accepts(current: -1, incoming: 1, limit: 1024))
		// A zero-or-negative span writes nothing, so it cannot breach the ceiling.
		XCTAssertTrue(WebManagerTransferLimits.accepts(current: 1024, incoming: 0, limit: 1024))
	}

	// MARK: - Free-space preflight

	func testReserveIsRequiredOnTopOfTheUpload() {
		let upload: Int = 100
		let reserve: Int64 = 50
		XCTAssertTrue(WebManagerTransferLimits.hasRoom(freeBytes: 150, requiredBytes: upload, reserve: reserve))
		XCTAssertFalse(WebManagerTransferLimits.hasRoom(freeBytes: 149, requiredBytes: upload, reserve: reserve))
	}

	func testUnknownCapacityStaysPermissive() {
		// A volume that will not report capacity must not block every upload.
		XCTAssertTrue(WebManagerTransferLimits.hasRoom(freeBytes: nil, requiredBytes: 1_000_000))
	}

	func testSwappingErrorIsTreatedAsNoRoom() {
		XCTAssertFalse(WebManagerTransferLimits.hasRoom(freeBytes: -1, requiredBytes: 0, reserve: 0))
	}

	func testDocumentedLimitsAreOrderedAndNonZero() {
		XCTAssertGreaterThan(WebManagerTransferLimits.inbox, 0)
		XCTAssertGreaterThan(WebManagerTransferLimits.signing, WebManagerTransferLimits.inbox)
	}

	// MARK: - WebManagerUploadFile accounting

	private func fixture(_ body: (URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		try body(root)
	}

	func testUploadFileCountsWrittenBytes() throws {
		try fixture { root in
			let upload = try WebManagerUploadFile(
				destination: root.appendingPathComponent("a.ipa"),
				maximumBytes: 10
			)
			try upload.write(Data(repeating: 1, count: 4))
			XCTAssertEqual(upload.written, 4)
			XCTAssertTrue(upload.willAccept(6))
			XCTAssertFalse(upload.willAccept(7))
			try upload.write(Data(repeating: 2, count: 6))
			XCTAssertEqual(upload.written, 10)
			XCTAssertFalse(upload.willAccept(1))
			try upload.commit()
			XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a.ipa")).count, 10)
		}
	}

	func testRefusedUploadLeavesNoPartialAndKeepsExistingFile() throws {
		try fixture { root in
			let destination = root.appendingPathComponent("existing.ipa")
			try Data([9]).write(to: destination)
			let upload = try WebManagerUploadFile(destination: destination, maximumBytes: 2)
			try upload.write(Data([1, 2]))
			XCTAssertFalse(upload.willAccept(1))
			upload.abort()
			XCTAssertEqual(try Data(contentsOf: destination), Data([9]))
			XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.ipa"])
		}
	}
}
