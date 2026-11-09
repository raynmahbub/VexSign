import Foundation
import XCTest
@testable import VexSign

final class OptionsCompatibilityTests: XCTestCase {
	func testAutomaticExtensionRemovalRequiresOptInEvenForOlderOptions() throws {
		XCTAssertFalse(Options.defaultOptions.autoRemoveUnsupportedExtensions)

		let encoded = try JSONEncoder().encode(Options.defaultOptions)
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object.removeValue(forKey: "autoRemoveUnsupportedExtensions")
		let olderData = try JSONSerialization.data(withJSONObject: object)

		let decoded = try JSONDecoder().decode(Options.self, from: olderData)
		XCTAssertFalse(decoded.autoRemoveUnsupportedExtensions)
	}

	func testExplicitExtensionRemovalChoicePersists() throws {
		for enabled in [false, true] {
			var options = Options.defaultOptions
			options.autoRemoveUnsupportedExtensions = enabled

			let decoded = try JSONDecoder().decode(Options.self, from: JSONEncoder().encode(options))
			XCTAssertEqual(decoded.autoRemoveUnsupportedExtensions, enabled)
		}
	}
}
