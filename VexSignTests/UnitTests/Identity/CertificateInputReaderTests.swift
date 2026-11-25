//
//  CertificateInputReaderTests.swift
//  VexSignTests
//
//  The reader is the one funnel that stops a multi-gigabyte file from being loaded
//  into memory before a decoder sees it. It is small, security-relevant and had no
//  tests, so these pin its three refusals and its happy path.
//

import XCTest
@testable import VexSign

final class CertificateInputReaderTests: XCTestCase {

	private var directory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("vexsign-reader-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let directory { try? FileManager.default.removeItem(at: directory) }
		try super.tearDownWithError()
	}

	private func write(_ bytes: Int, name: String = "input.p12") throws -> URL {
		let url = directory.appendingPathComponent(name)
		try Data(repeating: 0x00, count: bytes).write(to: url)
		return url
	}

	func testReadsARegularFileWithinTheLimit() throws {
		let url = try write(64)
		XCTAssertEqual(try CertificateInputReader.read(url).count, 64)
	}

	func testRefusesAFileOverTheLimit() throws {
		let url = try write(16)
		XCTAssertThrowsError(try CertificateInputReader.read(url, maximumBytes: 8)) { error in
			XCTAssertEqual(error as? CertificateInputReader.ReadError, .tooLarge)
		}
	}

	func testRefusesADirectoryEvenThoughItHasASize() throws {
		let url = directory.appendingPathComponent("folder", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		XCTAssertThrowsError(try CertificateInputReader.read(url)) { error in
			XCTAssertEqual(error as? CertificateInputReader.ReadError, .invalidFile)
		}
	}

	func testRefusesNonsenseLimitsRatherThanReadingUnbounded() throws {
		let url = try write(4)
		XCTAssertThrowsError(try CertificateInputReader.read(url, maximumBytes: 0)) { error in
			XCTAssertEqual(error as? CertificateInputReader.ReadError, .invalidFile)
		}
	}

	func testMissingFileThrowsInsteadOfReturningEmptyData() {
		let missing = directory.appendingPathComponent("absent.p12")
		XCTAssertThrowsError(try CertificateInputReader.read(missing))
	}
}
