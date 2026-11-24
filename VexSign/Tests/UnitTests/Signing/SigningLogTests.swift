//
//  SigningLogTests.swift
//  VexSignTests
//
//  `SigningLog` is the buffer behind the signing console and behind the log text that
//  `DiagnosticBundleExporter` puts in a report a user attaches to a bug. Nothing tested it.
//
//  The two behaviours worth pinning are the ones a refactor can silently break and a reviewer
//  cannot see in the UI: the cap that keeps a long signing run from growing both consoles
//  without bound, and the export shape (oldest first, `ISO8601` stamps, severity prefixes)
//  that people and parsers read.
//

import XCTest
@testable import VexSign

final class SigningLogTests: XCTestCase {

	private func entry(_ message: String, _ kind: LogKind = .info, date: Date? = nil) -> LogEntry {
		LogEntry(date: date, category: "test", message: message, kind: kind)
	}

	// MARK: - The cap

	func testABatchGoesInFrontOfTheExistingEntries() {
		let merged = SigningLog.merged([entry("newest"), entry("older")], onto: [entry("previous")], limit: 10)
		XCTAssertEqual(merged.map(\.message), ["newest", "older", "previous"])
	}

	func testTheCapKeepsTheNewestEntriesAndDropsTheOldest() {
		let existing = (1...3).map { entry("existing \($0)") }
		let merged = SigningLog.merged([entry("new one")], onto: existing, limit: 3)
		XCTAssertEqual(merged.map(\.message), ["new one", "existing 1", "existing 2"])
	}

	func testABatchLargerThanTheCapIsTruncatedFromTheOldEnd() {
		let batch = (1...5).map { entry("batch \($0)") }
		let merged = SigningLog.merged(batch, onto: [], limit: 2)
		XCTAssertEqual(merged.map(\.message), ["batch 1", "batch 2"])
	}

	func testAZeroLimitKeepsNothingRatherThanTrapping() {
		XCTAssertTrue(SigningLog.merged([entry("anything")], onto: [entry("older")], limit: 0).isEmpty)
	}

	func testTheDefaultLimitIsTheConfiguredOne() {
		// Ten past the cap, in the order the console would hold them: the oldest ten fall off.
		let batch = (1...(SigningLog.maxEntries + 10)).map { entry("batch \($0)") }
		let merged = SigningLog.merged(batch, onto: [])
		XCTAssertEqual(merged.count, SigningLog.maxEntries)
		XCTAssertEqual(merged.first?.message, "batch 1")
		XCTAssertEqual(merged.last?.message, "batch \(SigningLog.maxEntries)")
	}

	// MARK: - The export shape

	func testExportWritesOldestFirstWithSeverityPrefixes() {
		let older = entry("plain line", .info, date: Date(timeIntervalSince1970: 1_700_000_000))
		let warning = entry("careful", .warn, date: Date(timeIntervalSince1970: 1_700_000_060))
		let failure = entry("it broke", .error, date: Date(timeIntervalSince1970: 1_700_000_120))
		// Newest first going in, oldest first coming out: the artifact reads like a transcript.
		let text = SigningLog.shared.exportText([failure, warning, older])
		let lines = text.components(separatedBy: "\n")
		XCTAssertEqual(lines.count, 3)
		XCTAssertTrue(lines[0].hasSuffix("plain line"), lines[0])
		XCTAssertTrue(lines[1].contains("WARNING: careful"), lines[1])
		XCTAssertTrue(lines[2].contains("ERROR: it broke"), lines[2])
		XCTAssertTrue(lines[0].hasPrefix("2023-11-14T"), lines[0])
	}

	func testAnEntryWithoutADateIsStillOneLine() {
		let text = SigningLog.shared.exportText([entry("no timestamp", .detail)])
		XCTAssertEqual(text, "no timestamp")
		XCTAssertFalse(text.contains("\n"))
	}

	func testExportingNothingIsAnEmptyStringNotANewline() {
		XCTAssertEqual(SigningLog.shared.exportText([]), "")
	}
}
