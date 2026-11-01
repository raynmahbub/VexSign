//
//  IntegrityAndParsingTests.swift
//  VexSignTests
//
//  Covers the screenshots decoder that replaced the old empty-array stub in
//  AltSourceKit, the SHA-256 integrity helpers, and the entitlements presets.
//

import XCTest
import AltSourceKit
@testable import VexSign

final class IntegrityAndParsingTests: XCTestCase {

	// MARK: Screenshots decoding (ASRepository.App.Screenshots)

	private func decodeScreenshots(_ json: String) throws -> ASRepository.App.Screenshots {
		try JSONDecoder().decode(ASRepository.App.Screenshots.self, from: Data(json.utf8))
	}

	/// Format 1: a flat array of URL strings (AltStore semantics: the iPhone set).
	func testScreenshotsFlatStringArrayDecodesAsIPhoneSet() throws {
		let shots = try decodeScreenshots(#"["https://example.com/1.png","https://example.com/2.png"]"#)
		XCTAssertEqual(shots.iPhone?.count, 2)
		XCTAssertTrue(shots.iPad?.isEmpty ?? false)
	}

	/// Formats 2+3: dictionaries with url/width/height, mixed with plain strings.
	func testScreenshotsMixedStringsAndDictionariesDecode() throws {
		let json = #"["https://example.com/a.png", {"url": "https://example.com/b.png", "width": 100, "height": 200}]"#
		let shots = try decodeScreenshots(json)
		XCTAssertEqual(shots.iPhone, [
			URL(string: "https://example.com/a.png")!,
			URL(string: "https://example.com/b.png")!
		])
	}

	/// Format 4: a dictionary with iphone/ipad arrays.
	func testScreenshotsKeyedByDeviceDecodesBothSets() throws {
		let json = #"{"iphone": ["https://example.com/i.png"], "ipad": [{"url": "https://example.com/pad.png"}]}"#
		let shots = try decodeScreenshots(json)
		XCTAssertEqual(shots.iPhone, [URL(string: "https://example.com/i.png")!])
		XCTAssertEqual(shots.iPad, [URL(string: "https://example.com/pad.png")!])
	}

	/// Malformed entries (nulls, numbers) are skipped without breaking the decode.
	func testScreenshotsNullAndGarbageElementsAreSkipped() throws {
		let json = #"[null, "https://example.com/ok.png", 42]"#
		let shots = try decodeScreenshots(json)
		XCTAssertEqual(shots.iPhone, [URL(string: "https://example.com/ok.png")!])
	}

	// MARK: FileIntegrity

	private func makeTempFile(content: String) throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("vexsign-integrity-\(UUID().uuidString).txt")
		try Data(content.utf8).write(to: url)
		return url
	}

	func testSHA256OfKnownContent() throws {
		let url = try makeTempFile(content: "hello")
		defer { try? FileManager.default.removeItem(at: url) }

		XCTAssertEqual(
			FileIntegrity.sha256(of: url),
			"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
		)
	}

	func testNormalizeAcceptsPrefixCaseAndWhitespace() {
		let hash = "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"
		XCTAssertEqual(FileIntegrity.normalize("  SHA256:\(hash)\n"), hash.lowercased())
		XCTAssertEqual(FileIntegrity.normalize(hash), hash.lowercased())
	}

	func testMatchesDetectsMatchAndMismatch() throws {
		let url = try makeTempFile(content: "hello")
		defer { try? FileManager.default.removeItem(at: url) }

		let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
		XCTAssertTrue(FileIntegrity.matches(url, expected: "SHA256:\(expected.uppercased())"))
		XCTAssertFalse(FileIntegrity.matches(url, expected: String(repeating: "0", count: 64)))
	}

	// MARK: Entitlements presets

	func testEntitlementsPresetsAreNonEmptyAndTyped() {
		for preset in EntitlementsPreset.allCases {
			let values = preset.values
			XCTAssertFalse(values.isEmpty, "\(preset.rawValue) has no values")
			for (key, value) in values {
				XCTAssertFalse(key.isEmpty, "\(preset.rawValue) has an empty key")
				XCTAssertTrue(
					value is Bool || value is String || value is [String],
					"\(preset.rawValue): unexpected value type for \(key)"
				)
			}
		}
	}
}
