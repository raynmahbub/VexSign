import Foundation
import XCTest
@testable import VexSign

final class OptionsCompatibilityTests: XCTestCase {
	func testOlderSavedOptionsDefaultAutomaticExtensionCompatibilityToOff() throws {
		let encoded = try JSONEncoder().encode(Options.defaultOptions)
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object.removeValue(forKey: "autoRemoveUnsupportedExtensions")
		let olderData = try JSONSerialization.data(withJSONObject: object)

		let decoded = try JSONDecoder().decode(Options.self, from: olderData)
		XCTAssertFalse(decoded.autoRemoveUnsupportedExtensions)
	}

	func testAutomaticExtensionCompatibilityPersistsWhenEnabled() throws {
		var options = Options.defaultOptions
		options.autoRemoveUnsupportedExtensions = true

		let decoded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
		XCTAssertTrue(decoded.autoRemoveUnsupportedExtensions)
	}
}
