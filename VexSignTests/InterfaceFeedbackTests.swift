import Foundation
import XCTest
@testable import VexSign

final class InterfaceFeedbackTests: XCTestCase {
    @MainActor
    func testInterfaceSoundIsOptIn() throws {
        let suite = "VexSignTests.interfaceFeedback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(InterfaceFeedback.soundsEnabled(in: defaults))
        defaults.set(true, forKey: InterfaceFeedback.soundPreferenceKey)
        XCTAssertTrue(InterfaceFeedback.soundsEnabled(in: defaults))
        defaults.set(false, forKey: InterfaceFeedback.soundPreferenceKey)
        XCTAssertFalse(InterfaceFeedback.soundsEnabled(in: defaults))
    }
}
