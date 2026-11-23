//
//  FilePreviewLoaderTests.swift
//  VexSignTests
//
//  One loader now feeds both preview screens, so its two decisions are tested here:
//  what a preview shows, and what it refuses to read.
//

import XCTest
@testable import VexSign

@MainActor
final class FilePreviewLoaderTests: XCTestCase {

	private var root: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent("FilePreviewLoaderTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let root {
			do { try FileManager.default.removeItem(at: root) } catch { /* temp directory */ }
		}
		root = nil
		try super.tearDownWithError()
	}

	// MARK: Hex

	func testHexDumpShowsOffsetHexAndAscii() {
		// "AB\0": two printable bytes and one that must render as a dot.
		let dump = FilePreviewLoader.hex(from: Data([0x41, 0x42, 0x00]))
		let firstLine = dump.split(separator: "\n").first.map(String.init) ?? ""

		XCTAssertTrue(firstLine.hasPrefix("00000000  "), "the offset column is what makes a peek readable")
		XCTAssertTrue(firstLine.contains("41 42 00"))
		XCTAssertTrue(firstLine.hasSuffix("AB."))
	}

	func testUnreadableInputIsReportedTheSameWayForBothViews() {
		let missing = FilePreviewLoader.hex(from: nil)
		let empty = FilePreviewLoader.hex(from: Data())

		XCTAssertEqual(missing, empty)
		XCTAssertFalse(missing.isEmpty)
	}

	// MARK: Strings

	func testStringsKeepsPrintableRunsOfFourOrMore() {
		var data = Data("abc".utf8)
		data.append(0)
		data.append(contentsOf: Array("hello".utf8))

		let strings = FilePreviewLoader.strings(from: data)

		XCTAssertTrue(strings.contains("hello"))
		XCTAssertFalse(strings.contains("abc"), "a three-byte run is noise, not a string")
	}

	func testStringsReportsWhenNothingIsPrintable() {
		let strings = FilePreviewLoader.strings(from: Data([0x00, 0x01, 0x02, 0x03, 0x04]))
		XCTAssertFalse(strings.isEmpty)
		XCTAssertFalse(strings.contains("\\0"), "control bytes are never rendered")
	}

	// MARK: Read limits

	func testAFileAboveTheTextLimitIsNotRead() throws {
		let file = root.appendingPathComponent("big.log")
		XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
		let handle = try FileHandle(forWritingTo: file)
		try handle.truncate(atOffset: UInt64(FilePreviewLimit.textBytes + 1))
		try handle.close()

		XCTAssertFalse(IPAFileLoader.isWithinReadLimit(file), "the size gate must see the real size")
		XCTAssertNil(IPAFileLoader.text(at: file))
		XCTAssertNil(IPAFileLoader.plistText(at: file))
		XCTAssertNil(IPAFileLoader.plist(at: file))
	}

	func testTheLimitsLeaveRoomForRealMetadataAndStayBelowABundle() {
		// Text needs the room of a `.strings` file or a plist and nothing more; the unit
		// the strings extractor reads is clamped by `head(of:count:)` at 64 KB.
		XCTAssertGreaterThan(FilePreviewLimit.textBytes, 0)
		XCTAssertGreaterThanOrEqual(FilePreviewLimit.imageBytes, FilePreviewLimit.textBytes)
		XCTAssertLessThanOrEqual(FilePreviewLimit.stringsBytes, 65_536, "head(of:count:) clamps to 64 KB")
		XCTAssertLessThanOrEqual(FilePreviewLimit.hexBytes, FilePreviewLimit.stringsBytes)
	}

	func testASmallFileStillReads() throws {
		let file = root.appendingPathComponent("small.txt")
		try Data("hello".utf8).write(to: file)

		XCTAssertTrue(IPAFileLoader.isWithinReadLimit(file))
		XCTAssertEqual(IPAFileLoader.text(at: file), "hello")
	}
}
