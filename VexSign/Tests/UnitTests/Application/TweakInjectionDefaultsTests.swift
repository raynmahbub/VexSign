//
//  TweakInjectionDefaultsTests.swift
//  VexSignTests
//
//  the bulk "inject by default" screen. The list logic is pure so it can be tested here
//  without building a view; the view itself is a thin binding over `TweakManager.update`.
//

import Foundation
import XCTest
@testable import VexSign

final class TweakInjectionDefaultsTests: XCTestCase {
	private func tweak(
		_ name: String,
		enabled: Bool = true,
		inject: Bool = false,
		exceptions: [String] = []
	) -> ManagedTweak {
		ManagedTweak(
			name: name,
			notes: nil,
			isEnabled: enabled,
			injectByDefault: inject,
			autoInjectBundleIds: exceptions
		)
	}

	func testBackupMergeDropsDuplicateTweakAndFolderIdentities() {
		let sharedID = UUID()
		let firstTweak = tweak("first")
		var duplicateTweak = tweak("duplicate")
		duplicateTweak.id = firstTweak.id
		let existingTweak = tweak("already present")
		let chosenTweaks = TweakManager.uniqueBackupItems(
			[firstTweak, duplicateTweak], excluding: [existingTweak.id]
		)
		XCTAssertEqual(chosenTweaks.map(\.id), [firstTweak.id])

		let firstFolder = TweakFolder(id: sharedID, name: "first")
		let duplicateFolder = TweakFolder(id: sharedID, name: "duplicate")
		let existingFolder = TweakFolder(name: "already present")
		let chosenFolders = TweakManager.uniqueBackupItems(
			[firstFolder, duplicateFolder], excluding: [existingFolder.id]
		)
		XCTAssertEqual(chosenFolders.map(\.id), [sharedID])
	}

	func testExtensionTargetSelectionRejectsMissingAndAmbiguousNames() throws {
		let widget = URL(fileURLWithPath: "/app/PlugIns/Widget.appex", isDirectory: true)
		let share = URL(fileURLWithPath: "/app/Extensions/Share.appex", isDirectory: true)
		let duplicate = URL(fileURLWithPath: "/app/Extensions/Widget.appex", isDirectory: true)
		let available = [widget, share]
		XCTAssertEqual(try TweakExtensionTargets.resolve(.mainOnly, available: available), [])
		XCTAssertEqual(try TweakExtensionTargets.resolve(.all, available: available), available)
		XCTAssertEqual(try TweakExtensionTargets.resolve(.selected([]), available: available), [])
		XCTAssertEqual(try TweakExtensionTargets.resolve(.selected(["Widget.appex", "Widget.appex"]), available: available), [widget])
		XCTAssertThrowsError(try TweakExtensionTargets.resolve(.selected(["Widget.appex", "Missing.appex"]), available: available)) { error in
			XCTAssertEqual(error as? TweakExtensionTargets.SelectionError, .missing("Missing.appex"))
		}
		XCTAssertThrowsError(try TweakExtensionTargets.resolve(.selected(["Widget.appex"]), available: [widget, duplicate])) { error in
			XCTAssertEqual(error as? TweakExtensionTargets.SelectionError, .ambiguous("Widget.appex"))
		}
	}

	func testStrictExtensionEnumerationRejectsInvalidTargets() throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) } // try? ok: test teardown
		XCTAssertTrue(try AppExtensionEnumerator.appexBundlesForInjection(in: root).isEmpty)
		let plugins = root.appendingPathComponent("PlugIns", isDirectory: true)
		try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
		let widget = plugins.appendingPathComponent("Widget.appex", isDirectory: true)
		try fm.createDirectory(at: widget, withIntermediateDirectories: true)
		XCTAssertEqual(try AppExtensionEnumerator.appexBundlesForInjection(in: root).map(\.lastPathComponent), ["Widget.appex"])
		let invalid = plugins.appendingPathComponent("Broken.appex")
		try Data("not a directory".utf8).write(to: invalid)
		XCTAssertThrowsError(try AppExtensionEnumerator.appexBundlesForInjection(in: root)) { error in
			XCTAssertEqual(error as? AppExtensionEnumerator.EnumerationError, .invalidExtension("Broken.appex"))
		}
		try fm.removeItem(at: invalid)
		let link = plugins.appendingPathComponent("Link.appex")
		try fm.createSymbolicLink(at: link, withDestinationURL: widget)
		XCTAssertThrowsError(try AppExtensionEnumerator.appexBundlesForInjection(in: root))
		try fm.removeItem(at: link)
		try fm.removeItem(at: plugins)
		try Data("not a directory".utf8).write(to: root.appendingPathComponent("Extensions"))
		XCTAssertThrowsError(try AppExtensionEnumerator.appexBundlesForInjection(in: root)) { error in
			XCTAssertEqual(error as? AppExtensionEnumerator.EnumerationError, .invalidDirectory("Extensions"))
		}
	}

	func testExtensionInjectionRejectsMissingExecutableAndFailedLoadCommand() {
		let extensionURL = URL(fileURLWithPath: "/tmp/Widget.appex", isDirectory: true)
		let executable = extensionURL.appendingPathComponent("Widget")
		var called = false
		XCTAssertThrowsError(try TweakExtensionInjector.inject(
			into: extensionURL, dylibName: "test.dylib", path: .executable_path, folder: .frameworks,
			resolveExecutable: { _ in nil }, addLoadCommand: { _, _ in called = true; return true }
		)) { error in
			XCTAssertEqual(error as? TweakExtensionInjector.Failure, .missingExecutable("Widget.appex"))
		}
		XCTAssertFalse(called)
		XCTAssertThrowsError(try TweakExtensionInjector.inject(
			into: extensionURL, dylibName: "test.dylib", path: .executable_path, folder: .frameworks,
			resolveExecutable: { _ in executable }, addLoadCommand: { _, _ in false }
		)) { error in
			XCTAssertEqual(error as? TweakExtensionInjector.Failure,
			               .loadCommandFailed(tweak: "test.dylib", extensionName: "Widget.appex"))
		}
	}

	func testExtensionInjectionUsesTheCorrectLoadPaths() throws {
		let extensionURL = URL(fileURLWithPath: "/tmp/Widget.appex", isDirectory: true)
		let executable = extensionURL.appendingPathComponent("Widget")
		let cases: [(String, Options.InjectPath, Options.InjectFolder, String)] = [
			("test.dylib", .executable_path, .root, "@executable_path/../../test.dylib"),
			("test.dylib", .executable_path, .frameworks, "@executable_path/../../Frameworks/test.dylib"),
			("Helper.framework/Helper", .executable_path, .root, "@executable_path/../../Frameworks/Helper.framework/Helper"),
			("Helper.framework/Helper", .rpath, .frameworks, "@rpath/Helper.framework/Helper")
		]
		for (name, path, folder, expected) in cases {
			var actual: String?
			try TweakExtensionInjector.inject(into: extensionURL, dylibName: name, path: path, folder: folder,
				resolveExecutable: { _ in executable }, addLoadCommand: { target, loadPath in
					XCTAssertEqual(target, executable)
					actual = loadPath
					return true
				})
			XCTAssertEqual(actual, expected)
		}
	}

	func testFrameworkLoadNameUsesBundleAndExecutableNames() {
		let framework = URL(fileURLWithPath: "/tmp/App/Frameworks/Helper.framework", isDirectory: true)
		let executable = framework.appendingPathComponent("HelperBinary")
		XCTAssertEqual(TweakFrameworkLoad.name(framework: framework, executable: executable),
		               "Helper.framework/HelperBinary")
	}

	func testDebianDataMemberAcceptsOneSupportedArchive() throws {
		for name in ["data.tar", "data.tar.gz", "data.tar.xz", "data.tar.lzma", "data.tar.bz2"] {
			XCTAssertEqual(try DebianDataMember.select(from: ["debian-binary", "control.tar.gz", name]), name)
		}
	}

	func testDebianDataMemberRejectsMissingAmbiguousAndUnsupportedArchives() {
		func expect(_ names: [String], _ expected: DebianDataMember.SelectionError) {
			XCTAssertThrowsError(try DebianDataMember.select(from: names)) { error in
				XCTAssertEqual(error as? DebianDataMember.SelectionError, expected)
			}
		}
		expect(["debian-binary", "control.tar.gz"], .missing)
		expect(["data.tar.lz4"], .unsupported("data.tar.lz4"))
		expect(["data.tar.gz", "data.tar.zst"], .multiple)
		expect(["data.tar", "data.tar.xz"], .multiple)
		// The compression modern packages use, and the one a repository switched to first.
		XCTAssertNoThrow(try DebianDataMember.select(from: ["data.tar.zst"]))
	}

	func testUncompressedDebianTarExtractsInOnePass() throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) } // try? ok: test teardown
		let contents = Data("payload".utf8)
		var header = Data(repeating: 0, count: 512)
		func put(_ value: String, at offset: Int) {
			header.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
		}
		put("Library/test.txt", at: 0)
		put("0000644\0", at: 100)
		put("0000000\0", at: 108)
		put("0000000\0", at: 116)
		put(String(format: "%011o", contents.count) + "\0", at: 124)
		put("00000000000\0", at: 136)
		put("        ", at: 148)
		put("0", at: 156)
		put("ustar\0", at: 257)
		put("00", at: 263)
		let checksum = header.reduce(0) { $0 + Int($1) }
		put(String(format: "%06o", checksum) + "\0 ", at: 148)
		var tar = header + contents
		tar.append(Data(repeating: 0, count: 512 - contents.count))
		tar.append(Data(repeating: 0, count: 1024))
		let file = root.appendingPathComponent("data.tar")
		try tar.write(to: file)
		let extracted = try DebianDataMember.extract(file)
		XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("Library/test.txt")), contents)
	}

	func testFailedTarExtractionRemovesPartialWorkspaceAndKeepsInput() throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) } // try? ok: test teardown

		func entry(_ name: String, _ contents: Data) -> Data {
			var header = Data(repeating: 0, count: 512)
			func put(_ value: String, at offset: Int) {
				header.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
			}
			put(name, at: 0)
			put("0000644\0", at: 100)
			put("0000000\0", at: 108)
			put("0000000\0", at: 116)
			put(String(format: "%011o", contents.count) + "\0", at: 124)
			put("00000000000\0", at: 136)
			put("        ", at: 148)
			put("0", at: 156)
			put("ustar\0", at: 257)
			put("00", at: 263)
			let checksum = header.reduce(0) { $0 + Int($1) }
			put(String(format: "%06o", checksum) + "\0 ", at: 148)
			var result = header + contents
			let padding = (512 - contents.count % 512) % 512
			result.append(Data(repeating: 0, count: padding))
			return result
		}

		// The second file needs a directory where the first entry wrote a file.
		let conflicting = entry("parent", Data("first".utf8))
			+ entry("parent/child", Data("second".utf8)) + Data(repeating: 0, count: 1024)
		for data in [Data("truncated tar".utf8), conflicting] {
			let source = root.appendingPathComponent("data.tar")
			try data.write(to: source)
			var file = source
			XCTAssertThrowsError(try extractFile(at: &file))
			XCTAssertEqual(file, source)
			XCTAssertEqual(try Data(contentsOf: source), data)
			XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), ["data.tar"])
		}
	}

	func testManagedTweakFailureStopsInjectionInsteadOfReportingSuccess() async throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? fm.removeItem(at: root) } // try? ok: test teardown
		let app = root.appendingPathComponent("App.app", isDirectory: true)
		// Skip auto-inserting ElleKit so the test isolates the missing managed file.
		try fm.createDirectory(at: app.appendingPathComponent("Frameworks/CydiaSubstrate.framework"), withIntermediateDirectories: true)
		let missing = root.appendingPathComponent("missing.dylib")
		let file = TweakInjectionFile(fileURL: missing, fileName: "missing.dylib", fileType: .dylib, config: .default)
		var options = Options.defaultOptions
		options.tweakInjections = [TweakInjectionSpec(displayName: "Missing", isManaged: true, files: [file])]
		do {
			try await TweakHandler(app: app, options: options).getInputFiles()
			XCTFail("An enabled missing tweak must fail the signing step")
		} catch let error as TweakInjectionFailure {
			XCTAssertEqual(error.fileName, "missing.dylib")
		} catch {
			XCTFail("Expected a named injection failure, got \(error)")
		}
	}

	func testUnsupportedDebianDataFailsManagedInjection() async throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer { try? fm.removeItem(at: root) } // try? ok: test teardown
		let app = root.appendingPathComponent("App.app", isDirectory: true)
		try fm.createDirectory(at: app.appendingPathComponent("Frameworks/CydiaSubstrate.framework"), withIntermediateDirectories: true)
		func field(_ value: String, _ width: Int) -> String {
			value + String(repeating: " ", count: width - value.utf8.count)
		}
		let header = field("data.tar.lz4/", 16) + field("0", 12) + field("0", 6) + field("0", 6)
			+ field("100644", 8) + field("2", 10) + "`\n"
		let deb = root.appendingPathComponent("unsupported.deb")
		try (Data("!<arch>\n".utf8) + Data(header.utf8) + Data([1, 2])).write(to: deb)
		let preview = await TweakAnalyzer.analyze(fileURL: deb, type: .deb)
		XCTAssertTrue(preview.blocksInjection)
		XCTAssertTrue(preview.warnings.contains { $0.contains("data.tar.lz4") })
		XCTAssertFalse(preview.warnings.contains { $0.contains("No dylibs/frameworks/bundles") })
		let file = TweakInjectionFile(fileURL: deb, fileName: deb.lastPathComponent, fileType: .deb, config: .default)
		var options = Options.defaultOptions
		options.tweakInjections = [TweakInjectionSpec(displayName: "Unsupported", isManaged: true, files: [file])]
		do {
			try await TweakHandler(app: app, options: options).getInputFiles()
			XCTFail("Unsupported compression must not be reported as a successful injection")
		} catch let error as TweakInjectionFailure {
			XCTAssertEqual(error.underlying as? DebianDataMember.SelectionError, .unsupported("data.tar.lz4"))
		} catch {
			XCTFail("Expected a named injection failure, got \(error)")
		}
	}

	func testBrokenDebianPreviewReportsInspectionFailure() async throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) } // try? ok: test teardown
		let deb = root.appendingPathComponent("broken.deb")
		for bytes in [Data("not an ar archive".utf8), Data("!<arch>\n".utf8)] {
			try bytes.write(to: deb)
			let preview = await TweakAnalyzer.analyze(fileURL: deb, type: .deb)
			XCTAssertTrue(preview.blocksInjection)
			XCTAssertFalse(preview.warnings.isEmpty)
			XCTAssertFalse(preview.warnings.contains { $0.contains("No dylibs/frameworks/bundles") })
		}
	}

	func testTweakPlacementRejectsCollisionWithoutReplacingEitherItem() throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) } // try? ok: test teardown
		let source = root.appendingPathComponent("source/Example.bundle")
		let destination = root.appendingPathComponent("app/Example.bundle")
		try fm.createDirectory(at: source, withIntermediateDirectories: true)
		try fm.createDirectory(at: destination, withIntermediateDirectories: true)
		try Data("new".utf8).write(to: source.appendingPathComponent("marker"))
		try Data("old".utf8).write(to: destination.appendingPathComponent("marker"))
		XCTAssertThrowsError(try TweakPlacement.move(source, to: destination)) { error in
			XCTAssertTrue(error is TweakPlacement.Conflict)
		}
		XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("marker")), Data("new".utf8))
		XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("marker")), Data("old".utf8))
	}

	func testTweakPlacementMovesIntoNewDirectory() throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) } // try? ok: test teardown
		let source = root.appendingPathComponent("tweak.dylib")
		let destination = root.appendingPathComponent("App/Frameworks/tweak.dylib")
		try Data("new".utf8).write(to: source)
		try TweakPlacement.move(source, to: destination)
		XCTAssertFalse(fm.fileExists(atPath: source.path))
		XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
	}

	// MARK: - Matching

	func testEmptyQueryMatchesEverything() {
		XCTAssertTrue(TweakInjectionDefaults.matches(tweak("Choicy"), query: ""))
		XCTAssertTrue(TweakInjectionDefaults.matches(tweak("Choicy"), query: "   "))
	}

	func testSearchIsCaseAndDiacriticInsensitive() {
		XCTAssertTrue(TweakInjectionDefaults.matches(tweak("Café Patch"), query: "cafe"))
		XCTAssertTrue(TweakInjectionDefaults.matches(tweak("Choicy"), query: "CHO"))
		XCTAssertFalse(TweakInjectionDefaults.matches(tweak("Choicy"), query: "crane"))
	}

	// MARK: - Bulk apply

	func testApplyTurnsOnEveryEnabledMatchOnly() {
		let tweaks = [
			tweak("A"),
			tweak("B", inject: true),
			tweak("C", enabled: false),
			tweak("D")
		]

		let result = TweakInjectionDefaults.apply(true, to: tweaks, matching: "")

		XCTAssertEqual(result.map(\.injectByDefault), [true, true, false, true])
		// A disabled tweak is not silently switched on.
		XCTAssertFalse(result[2].injectByDefault)
	}

	func testApplyRespectsTheSearch() {
		let tweaks = [tweak("Choicy"), tweak("Crane")]
		let result = TweakInjectionDefaults.apply(true, to: tweaks, matching: "choicy")

		XCTAssertEqual(result.map(\.injectByDefault), [true, false])
	}

	func testApplyIsIdempotent() {
		let tweaks = [tweak("A", inject: true), tweak("B")]
		let once = TweakInjectionDefaults.apply(true, to: tweaks, matching: "")
		let twice = TweakInjectionDefaults.apply(true, to: once, matching: "")

		XCTAssertEqual(once.map(\.injectByDefault), twice.map(\.injectByDefault))
	}

	func testApplyOffLeavesExceptionsAlone() {
		let tweaks = [tweak("A", inject: true, exceptions: ["com.example.app"])]
		let result = TweakInjectionDefaults.apply(false, to: tweaks, matching: "")

		XCTAssertFalse(result[0].injectByDefault)
		XCTAssertEqual(result[0].autoInjectBundleIds, ["com.example.app"])
	}

	// MARK: - The rule the screen describes

	func testOnWithExceptionsSkipsTheListedApp() {
		let tweak = tweak("A", inject: true, exceptions: ["com.example.app"])
		XCTAssertTrue(tweak.autoInjects(into: "com.other.app"))
		XCTAssertFalse(tweak.autoInjects(into: "com.example.app"))
		XCTAssertFalse(tweak.autoInjects(into: "COM.EXAMPLE.APP"))
	}

	func testOffWithAllowListOnlyReachesTheListedApp() {
		let tweak = tweak("A", inject: false, exceptions: ["com.example.app"])
		XCTAssertTrue(tweak.autoInjects(into: "com.example.app"))
		XCTAssertFalse(tweak.autoInjects(into: "com.other.app"))
	}
}
