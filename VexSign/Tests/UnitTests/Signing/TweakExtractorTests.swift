//
//  TweakExtractorTests.swift
//  VexSignTests
//
//  The tweak pipeline had no test coverage beyond the injection defaults, and
//  `TweakExtractor` is the step every uploaded tweak passes through. `candidates(inDirectory:)`
//  is a pure filesystem walk, so the decisions that matter — which artifacts count, what is
//  skipped, how folders are named — can be pinned without building a `.deb` or a real IPA.
//

import XCTest
@testable import VexSign

final class TweakExtractorTests: XCTestCase {

	private var root: URL!

	override func setUpWithError() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent("TweakExtractorTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let root { try? FileManager.default.removeItem(at: root) }
	}

	private func touch(_ relative: String, bytes: Int = 4) throws -> URL {
		let url = root.appendingPathComponent(relative)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try Data(repeating: 0x7F, count: bytes).write(to: url)
		return url
	}

	private func makeDirectory(_ relative: String) throws -> URL {
		let url = root.appendingPathComponent(relative)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	// MARK: - What counts as injectable

	func testRecognisesEveryInjectableExtension() throws {
		_ = try touch("Reveal.dylib")
		_ = try touch("package.deb")
		_ = try makeDirectory("Orion.framework")
		_ = try touch("Orion.framework/Orion", bytes: 8)
		_ = try makeDirectory("Resources.bundle")
		_ = try makeDirectory("Widget.appex")
		_ = try touch("Widget.appex/Widget", bytes: 2)

		let candidates = TweakExtractor.candidates(inDirectory: root)
		XCTAssertEqual(
			Set(candidates.map(\.type)),
			Set([.dylib, .deb, .framework, .bundle, .appex]),
			"Every documented tweak artifact type must be surfaced"
		)
		XCTAssertEqual(candidates.count, 5, "A matched bundle must not also yield its contents")
	}

	func testIgnoresEverythingElseInTheTree() throws {
		_ = try touch("Plugin.dylib")
		_ = try touch("README.txt")
		_ = try touch("payload.zip")
		_ = try touch("Info.plist")
		_ = try touch("libSomething.dylib.bak")

		let candidates = TweakExtractor.candidates(inDirectory: root)
		XCTAssertEqual(candidates.map(\.name), ["Plugin.dylib"])
	}

	func testExtensionMatchingIsCaseInsensitive() throws {
		_ = try touch("LOUD.DYLIB")
		let candidates = TweakExtractor.candidates(inDirectory: root)
		XCTAssertEqual(candidates.first?.type, .dylib)
	}

	// MARK: - Traversal rules

	func testDescendsIntoSubdirectoriesAndNamesTheirFolder() throws {
		_ = try touch("Root.dylib")
		_ = try touch("Nested/Inner.dylib")
		_ = try touch("Nested/Deeper/Deepest.dylib")

		let candidates = TweakExtractor.candidates(inDirectory: root)
		let byName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.name, $0) })

		XCTAssertEqual(byName["Root.dylib"]?.folder, "", "A file at the root reports an empty folder")
		XCTAssertEqual(byName["Inner.dylib"]?.folder, "Nested")
		XCTAssertEqual(byName["Deepest.dylib"]?.folder, "Nested/Deeper")
	}

	func testDoesNotDescendIntoAMatchedFramework() throws {
		_ = try touch("Orion.framework/Versions/A/Orion.dylib", bytes: 16)
		let candidates = TweakExtractor.candidates(inDirectory: root)
		XCTAssertEqual(candidates.map(\.name), ["Orion.framework"], "The framework is the unit, not its inner dylib")
		XCTAssertGreaterThan(candidates.first?.size ?? 0, 0)
	}

	func testSkipsSymbolicLinks() throws {
		let target = try touch("Real.dylib")
		try FileManager.default.createSymbolicLink(
			at: root.appendingPathComponent("Link.dylib"),
			withDestinationURL: target
		)
		let candidates = TweakExtractor.candidates(inDirectory: root)
		XCTAssertEqual(candidates.map(\.name), ["Real.dylib"], "Symlinks are neither followed nor reported")
	}

	func testEmptyDirectoryYieldsNothing() {
		XCTAssertTrue(TweakExtractor.candidates(inDirectory: root).isEmpty)
	}

	func testMissingDirectoryYieldsNothingInsteadOfThrowing() {
		let missing = root.appendingPathComponent("does-not-exist")
		XCTAssertTrue(TweakExtractor.candidates(inDirectory: missing).isEmpty)
	}

	// MARK: - Presentation

	func testOrderingIsStableByTypeThenName() throws {
		_ = try touch("zeta.dylib")
		_ = try touch("Alpha.dylib")
		_ = try makeDirectory("Beta.framework")
		_ = try touch("aaa.deb")

		let candidates = TweakExtractor.candidates(inDirectory: root)
		XCTAssertEqual(candidates.map(\.name), ["aaa.deb", "Alpha.dylib", "zeta.dylib", "Beta.framework"])
	}

	func testRelativePathKeepsThePathBelowTheRoot() throws {
		_ = try touch("Nested/Inner.dylib")
		let candidate = try XCTUnwrap(TweakExtractor.candidates(inDirectory: root).first)
		XCTAssertTrue(candidate.relativePath.hasSuffix("Nested/Inner.dylib"), candidate.relativePath)
	}

	// MARK: - Type mapping

	func testFileTypeMapping() {
		XCTAssertEqual(TweakFileType(fileExtension: "dylib"), .dylib)
		XCTAssertEqual(TweakFileType(fileExtension: "DEB"), .deb)
		XCTAssertEqual(TweakFileType(fileExtension: "Framework"), .framework)
		XCTAssertEqual(TweakFileType(fileExtension: "appex"), .appex)
		XCTAssertEqual(TweakFileType(fileExtension: "txt"), .other)
		XCTAssertEqual(TweakFileType(fileExtension: ""), .other)
	}
}
