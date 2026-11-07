import Foundation
import XCTest
@testable import VexSign

final class OptionsCompatibilityTests: XCTestCase {
	func testAutomaticExtensionCompatibilityIsEnabledByDefault() throws {
		XCTAssertTrue(Options.defaultOptions.autoRemoveUnsupportedExtensions)

		let encoded = try JSONEncoder().encode(Options.defaultOptions)
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object.removeValue(forKey: "autoRemoveUnsupportedExtensions")
		let olderData = try JSONSerialization.data(withJSONObject: object)

		let decoded = try JSONDecoder().decode(Options.self, from: olderData)
		XCTAssertTrue(decoded.autoRemoveUnsupportedExtensions)
	}

	func testAutomaticExtensionCompatibilityCanBeTurnedOffAndPersists() throws {
		var options = Options.defaultOptions
		options.autoRemoveUnsupportedExtensions = false

		let decoded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
		XCTAssertFalse(decoded.autoRemoveUnsupportedExtensions)
	}
}
