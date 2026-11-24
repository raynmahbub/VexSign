//
//  OneShotTweakFilesTests.swift
//  VexSignTests
//
//  Regression tests for "Re-sign with last settings" stopping in the Customize step.
//
//  A tweak file added "just for this sign" used to be moved out of its staging directory by the
//  first run that used it. Its URL was then saved with the app's signing settings, so every later
//  run that reused them - a retry in the same sheet, a re-sign, Update All - stopped with "no such
//  file" before signing started. These tests pin the rules that replaced that: a run consumes a
//  copy, a missing file is named, and replayed settings report what they could not reuse.
//

import Foundation
import XCTest
@testable import VexSign

final class OneShotTweakFilesTests: XCTestCase {
	private var root: URL!
	private let fileManager = FileManager.default

	override func setUpWithError() throws {
		try super.setUpWithError()
		root = fileManager.temporaryDirectory
			.appendingPathComponent("OneShotTweakFilesTests-\(UUID().uuidString)", isDirectory: true)
		try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let root, fileManager.fileExists(atPath: root.path) {
			try fileManager.removeItem(at: root)
		}
		root = nil
		try super.tearDownWithError()
	}

	// MARK: - Fixtures

	/// A file staged the way the signing sheet stages one: alone in its own directory.
	private func stagedFile(_ name: String, contents: String = "payload", in folder: String) throws -> URL {
		let directory = root.appendingPathComponent(folder, isDirectory: true)
		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appendingPathComponent(name)
		try Data(contents.utf8).write(to: url)
		return url
	}

	private func workDirectory(_ name: String = "work") throws -> URL {
		let directory = root.appendingPathComponent(name, isDirectory: true)
		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	// MARK: - Staging

	func testStagingCopiesAndLeavesTheOriginalInPlace() throws {
		let original = try stagedFile("Tweak.dylib", contents: "first", in: "picked")
		let copies = try OneShotTweakFiles.stage([original], into: try workDirectory())

		XCTAssertEqual(copies.count, 1)
		XCTAssertNotEqual(copies[0].path, original.path)
		XCTAssertEqual(copies[0].lastPathComponent, "Tweak.dylib", "The engine names the installed file after this")
		XCTAssertTrue(fileManager.fileExists(atPath: original.path), "The file the user staged must survive the run")
		XCTAssertEqual(try Data(contentsOf: copies[0]), Data("first".utf8))
	}

	/// The regression itself. The engine moves its input into the app bundle; a second attempt
	/// used to find nothing where the first one had been.
	func testASecondAttemptStillHasItsInputAfterTheEngineConsumedTheFirstCopy() throws {
		let original = try stagedFile("Tweak.dylib", in: "picked")
		let bundle = try workDirectory("App.app")

		let first = try OneShotTweakFiles.stage([original], into: try workDirectory("run-1"))
		try fileManager.moveItem(at: first[0], to: bundle.appendingPathComponent("Tweak.dylib"))
		XCTAssertFalse(fileManager.fileExists(atPath: first[0].path), "The engine consumed its copy")

		let second = try OneShotTweakFiles.stage([original], into: try workDirectory("run-2"))
		XCTAssertTrue(fileManager.fileExists(atPath: second[0].path))
		XCTAssertTrue(fileManager.fileExists(atPath: original.path))
	}

	func testTwoFilesWithTheSameNameAreBothStaged() throws {
		let one = try stagedFile("Shared.dylib", contents: "one", in: "picked-1")
		let two = try stagedFile("Shared.dylib", contents: "two", in: "picked-2")

		let copies = try OneShotTweakFiles.stage([one, two], into: try workDirectory())

		XCTAssertEqual(copies.map(\.lastPathComponent), ["Shared.dylib", "Shared.dylib"])
		XCTAssertNotEqual(copies[0].path, copies[1].path)
		XCTAssertEqual(try Data(contentsOf: copies[0]), Data("one".utf8))
		XCTAssertEqual(try Data(contentsOf: copies[1]), Data("two".utf8))
	}

	func testADirectoryIsCopiedWithItsContents() throws {
		let framework = root.appendingPathComponent("picked/Hook.framework", isDirectory: true)
		try fileManager.createDirectory(at: framework, withIntermediateDirectories: true)
		try Data("binary".utf8).write(to: framework.appendingPathComponent("Hook"))

		let copies = try OneShotTweakFiles.stage([framework], into: try workDirectory())

		XCTAssertEqual(copies[0].lastPathComponent, "Hook.framework")
		XCTAssertEqual(try Data(contentsOf: copies[0].appendingPathComponent("Hook")), Data("binary".utf8))
		XCTAssertTrue(fileManager.fileExists(atPath: framework.appendingPathComponent("Hook").path))
	}

	func testNothingToStageCreatesNothing() throws {
		let work = try workDirectory()
		XCTAssertEqual(try OneShotTweakFiles.stage([], into: work), [])
		XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: work.path), [])
	}

	// MARK: - Missing files

	func testAMissingFileIsNamedAndNothingIsCopied() throws {
		let present = try stagedFile("Present.dylib", in: "picked-1")
		let gone = root.appendingPathComponent("picked-2/Gone.dylib")
		let alsoGone = root.appendingPathComponent("picked-3/AlsoGone.deb")
		let work = try workDirectory()

		XCTAssertThrowsError(try OneShotTweakFiles.stage([present, gone, alsoGone], into: work)) { error in
			XCTAssertEqual(
				error as? OneShotTweakFiles.Unavailable,
				OneShotTweakFiles.Unavailable(names: ["Gone.dylib", "AlsoGone.deb"]),
				"Every missing file is reported at once"
			)
		}
		XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: work.path), [],
			"A run that cannot have all of its inputs must not start copying some of them")
	}

	func testUnavailableListsOnlyWhatIsNotOnDisk() throws {
		let present = try stagedFile("Present.dylib", in: "picked-1")
		let gone = root.appendingPathComponent("picked-2/Gone.dylib")

		XCTAssertEqual(OneShotTweakFiles.unavailable([present, gone]), [gone])
		XCTAssertEqual(OneShotTweakFiles.unavailable([present]), [])
		XCTAssertEqual(OneShotTweakFiles.unavailable([]), [])
	}

	func testTheErrorNamesTheFileAndNeverItsPath() {
		let error = OneShotTweakFiles.Unavailable(names: ["Gone.dylib"])
		let description = error.localizedDescription

		XCTAssertTrue(description.contains("Gone.dylib"))
		XCTAssertFalse(description.contains(root.path), "A staging path is private to this device")
		XCTAssertFalse(description.contains("/"))
	}

	// MARK: - Names

	func testNamesKeepOrderAndDropDuplicates() {
		let urls = ["/tmp/a/One.dylib", "/tmp/b/Two.deb", "/tmp/c/One.dylib"].map { URL(fileURLWithPath: $0) }
		XCTAssertEqual(OneShotTweakFiles.names(urls), ["One.dylib", "Two.deb"])
		XCTAssertEqual(OneShotTweakFiles.names([]), [])
	}

	func testMergedJoinsListsWithoutEmptyOrRepeatedNames() {
		XCTAssertEqual(OneShotTweakFiles.merged(["A", "", "B"], nil, ["B", "C"]), ["A", "B", "C"])
		XCTAssertEqual(OneShotTweakFiles.merged(nil, nil), [])
	}

	// MARK: - Replay

	func testReplayingSettingsThatNeverHadOneShotFilesSaysNothing() {
		XCTAssertEqual(OneShotTweakFiles.replayNotices(for: []), [])
		XCTAssertEqual(OneShotTweakFiles.replayNotices(for: [""]), [])
	}

	func testReplayingSettingsThatHadOneShotFilesNamesThemOnce() {
		let notices = OneShotTweakFiles.replayNotices(for: ["Tweak.dylib", "Extra.deb", "Tweak.dylib"])

		XCTAssertEqual(notices.count, 1)
		XCTAssertTrue(notices[0].contains("Tweak.dylib, Extra.deb"))
		XCTAssertFalse(notices[0].contains("/"), "Names only: the notice ends up in the signing log")
	}
}
