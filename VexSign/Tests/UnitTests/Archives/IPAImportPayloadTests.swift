//
//  IPAImportPayloadTests.swift
//  VexSignTests
//
//  Which bundle an archive is allowed to import. `IPAImportPayload.application(in:)` is the
//  decision every IPA/TIPA/ZIP import makes before a payload is moved into the library, and
//  the layouts it accepts are the ones a user can actually produce when they share an app:
//  a standard `Payload/App.app`, an app at the top level, or an app one folder deep beside
//  its metadata.
//
//  The one-folder-deep case was refused before this file existed: the search for it was
//  reachable only when the caller passed a directory literally named `Payload`, which is the
//  opposite of the case it was written for. A `.zip` that wrapped the app in a folder failed
//  with "The archive does not contain an app bundle (.app)" after a full extraction.
//

import XCTest
@testable import VexSign

final class IPAImportPayloadTests: XCTestCase {

	private var root: URL!

	override func setUpWithError() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent("IPAImportPayloadTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let root { try? FileManager.default.removeItem(at: root) }
	}

	@discardableResult
	private func makeDirectory(_ relative: String) throws -> URL {
		let url = root.appendingPathComponent(relative, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	@discardableResult
	private func makeFile(_ relative: String) throws -> URL {
		let url = root.appendingPathComponent(relative)
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("binary".utf8).write(to: url)
		return url
	}

	/// Compares by resolved path: `appendingPathComponent(_:isDirectory:)` keeps a trailing
	/// slash that `contentsOfDirectory` does not return, and both name the same directory.
	private func assertApp(
		_ expected: URL,
		in payload: URL,
		_ message: String = "",
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		do {
			let found = try IPAImportPayload.application(in: payload)
			XCTAssertEqual(
				found.resolvingSymlinksInPath().standardizedFileURL.path,
				expected.resolvingSymlinksInPath().standardizedFileURL.path,
				message, file: file, line: line
			)
		} catch {
			XCTFail("\(message) Expected \(expected.path), got \(error)", file: file, line: line)
		}
	}

	private func assertThrows(
		_ expected: IPAImportPayload.ValidationError,
		in payload: URL,
		_ message: String = "",
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		XCTAssertThrowsError(try IPAImportPayload.application(in: payload), message, file: file, line: line) { error in
			guard let validation = error as? IPAImportPayload.ValidationError else {
				return XCTFail("Expected \(expected), got \(error)", file: file, line: line)
			}
			XCTAssertEqual(validation, expected, message, file: file, line: line)
		}
	}

	// MARK: - Standard layout

	func testStandardPayloadLayoutWins() throws {
		let app = try makeDirectory("Payload/Example.app")
		_ = try makeFile("Payload/Example.app/Example")
		assertApp(app, in: try makeDirectory("Payload"))
	}

	func testAppAtTheTopLevelOfAPlainArchive() throws {
		let app = try makeDirectory("Example.app")
		_ = try makeFile("Example.app/Example")
		assertApp(app, in: root)
	}

	// MARK: - One folder deep (the case that was refused)

	func testAppOneFolderDeepIsFound() throws {
		let app = try makeDirectory("Wrapped/Example.app")
		_ = try makeFile("Wrapped/Example.app/Example")
		_ = try makeFile("Wrapped/README.txt")
		assertApp(
			app,
			in: root,
			"A package that wraps the bundle in a folder must import, not fail as 'no app bundle'"
		)
	}

	func testAppOneFolderDeepBesideMetadataFolderIsFound() throws {
		let app = try makeDirectory("Release/Example.app")
		_ = try makeFile("Release/Example.app/Example")
		_ = try makeDirectory("__MACOSX/Example.app")
		assertApp(app, in: root, "__MACOSX is metadata, not a candidate")
	}

	func testTwoAppsOneFolderDeepAreAmbiguous() throws {
		_ = try makeDirectory("First/One.app")
		_ = try makeDirectory("Second/Two.app")
		assertThrows(.multipleApps, in: root, "Two bundles in different folders must not be chosen by directory order")
	}

	// MARK: - Refusals

	func testTwoTopLevelAppsAreRefused() throws {
		_ = try makeDirectory("First.app")
		_ = try makeDirectory("Second.app")
		assertThrows(.multipleApps, in: root)
	}

	func testNestedBundlesInsideTheAppAreNotSecondCandidates() throws {
		let app = try makeDirectory("Example.app")
		_ = try makeDirectory("Example.app/Watch/Watch.app")
		_ = try makeDirectory("Example.app/PlugIns/Widget.appex")
		assertApp(app, in: root)
	}

	func testAnEmptyExtractionNamesTheMissingPayload() throws {
		let payload = root.appendingPathComponent("Payload", isDirectory: true)
		assertThrows(.missingPayload, in: payload, "A missing Payload folder is reported as missing, not as an empty one")
	}

	func testAnEmptyPayloadFolderDoesNotReachSideways() throws {
		let payload = try makeDirectory("Payload")
		// A bundle beside the empty Payload folder is not evidence of a different layout.
		_ = try makeDirectory("Elsewhere.app")
		assertThrows(.missingApp, in: payload)
	}

	func testAFileMasqueradingAsAnAppIsRefused() throws {
		_ = try makeFile("Fake.app")
		assertThrows(.invalidApp, in: root)
	}

	func testAFileMasqueradingAsAnAppOneFolderDeepIsRefused() throws {
		_ = try makeFile("Wrapped/Fake.app")
		assertThrows(.invalidApp, in: root)
	}

	func testAnEmptyDirectoryYieldsNoApp() throws {
		assertThrows(.missingApp, in: root)
	}
}
