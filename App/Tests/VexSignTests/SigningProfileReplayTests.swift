//
//  SigningProfileReplayTests.swift
//  VexSignTests
//
//  What a saved signing profile may hand to a later run.
//
//  "Re-sign with last settings", Update All and named presets all replay an `Options` snapshot.
//  That snapshot used to include the URLs of tweak files staged for one sign in the temporary
//  directory. The first run consumed those files, so every replay stopped in the Customize step
//  with "no such file" - on a signed copy that was valid. Profiles written that way are already
//  on users' devices, which is why the rule is applied when a profile is read as well as when it
//  is saved.
//

import Foundation
import XCTest
@testable import VexSign

final class SigningProfileReplayTests: XCTestCase {
	private let staged = [
		URL(fileURLWithPath: "/private/var/tmp/VexSignTweak_AAAA/Tweak.dylib"),
		URL(fileURLWithPath: "/private/var/tmp/VexSignTweak_BBBB/Extra.deb")
	]

	private func profile(
		injecting files: [URL] = [],
		names: [String]? = nil,
		configure: (inout Options) -> Void = { _ in }
	) -> SigningProfile {
		var options = Options.defaultOptions
		options.injectionFiles = files
		configure(&options)
		return SigningProfile(
			bundleID: "com.example.app",
			options: options,
			certificateUUID: "certificate-1",
			savedAt: Date(timeIntervalSince1970: 1_700_000_000),
			oneShotFileNames: names
		)
	}

	// MARK: - Replay

	func testAProfileWithoutOneShotFilesIsReplayedUnchanged() {
		let saved = profile()
		XCTAssertEqual(saved.replayable(), saved)
		XCTAssertNil(saved.replayable().oneShotFileNames)
	}

	func testReplayDropsTheStagingURLsAndKeepsTheirNames() {
		let replay = profile(injecting: staged).replayable()

		XCTAssertEqual(replay.options.injectionFiles, [],
			"A later run must never be handed a URL into a temporary directory")
		XCTAssertEqual(replay.oneShotFileNames, ["Tweak.dylib", "Extra.deb"])
		XCTAssertEqual(replay.bundleID, "com.example.app")
		XCTAssertEqual(replay.certificateUUID, "certificate-1")
		XCTAssertEqual(replay.savedAt, Date(timeIntervalSince1970: 1_700_000_000))
	}

	func testReplayKeepsEveryOtherOption() {
		let saved = profile(injecting: staged) { options in
			options.removeFiles = ["Frameworks/Old.framework"]
			options.post_installAppAfterSigned = false
		}
		var expected = saved.options
		expected.injectionFiles = []

		XCTAssertEqual(saved.replayable().options, expected)
	}

	func testReplayIsStableOnceApplied() {
		let once = profile(injecting: staged).replayable()
		XCTAssertEqual(once.replayable(), once)
	}

	func testNamesRecordedEarlierAreKeptAndNotRepeated() {
		let replay = profile(injecting: staged, names: ["Tweak.dylib", "Older.dylib"]).replayable()
		XCTAssertEqual(replay.oneShotFileNames, ["Tweak.dylib", "Older.dylib", "Extra.deb"])
	}

	// MARK: - Profiles already on disk

	func testAProfileWrittenBeforeTheNameFieldExistedStillDecodes() throws {
		let data = try JSONEncoder().encode(profile(injecting: staged))
		var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		object.removeValue(forKey: "oneShotFileNames")
		let legacy = try JSONSerialization.data(withJSONObject: object)

		let decoded = try JSONDecoder().decode(SigningProfile.self, from: legacy)

		XCTAssertNil(decoded.oneShotFileNames)
		XCTAssertEqual(decoded.options.injectionFiles.map(\.path), staged.map(\.path),
			"Decoding alone does not rewrite stored data")
		XCTAssertEqual(decoded.replayable().options.injectionFiles, [])
		XCTAssertEqual(decoded.replayable().oneShotFileNames, ["Tweak.dylib", "Extra.deb"])
	}

	func testTheReplayedProfileSurvivesAnotherRoundTrip() throws {
		let replay = profile(injecting: staged).replayable()
		let decoded = try JSONDecoder().decode(SigningProfile.self, from: try JSONEncoder().encode(replay))
		XCTAssertEqual(decoded, replay)
	}

	// MARK: - Named presets

	func testANewPresetNeverCarriesOneShotFiles() {
		var options = Options.defaultOptions
		options.injectionFiles = staged
		options.removeFiles = ["Frameworks/Old.framework"]

		let preset = NamedSigningProfile(name: "Games", options: options, certificateUUID: nil)

		XCTAssertEqual(preset.options.injectionFiles, [])
		XCTAssertEqual(preset.options.removeFiles, ["Frameworks/Old.framework"])
	}

	func testAStoredOrImportedPresetIsCleanedWhenItIsRead() throws {
		var stored = NamedSigningProfile(name: "Games", options: Options.defaultOptions, certificateUUID: "certificate-1")
		stored.options.injectionFiles = staged
		let decoded = try JSONDecoder().decode(NamedSigningProfile.self, from: try JSONEncoder().encode(stored))
		XCTAssertEqual(decoded.options.injectionFiles.map(\.path), staged.map(\.path),
			"Decoding does not go through the initializer")

		let cleaned = decoded.withoutOneShotFiles()

		XCTAssertEqual(cleaned.options.injectionFiles, [])
		XCTAssertEqual(cleaned.id, stored.id)
		XCTAssertEqual(cleaned.name, "Games")
		XCTAssertEqual(cleaned.certificateUUID, "certificate-1")
		XCTAssertEqual(cleaned.withoutOneShotFiles(), cleaned)
	}
}
