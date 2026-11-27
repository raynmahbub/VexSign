//
//  HardwareAcceptanceSupport.swift
//  VexSignUITests
//
//  Explicit opt-in and skip reasons for acceptance cases that cannot be proven
//  in a simulator. These helpers never turn a missing device into a pass.
//

import Foundation
import XCTest

enum HardwareAcceptanceSupport {
    static let optInKey = "VEXSIGN_DEVICE_ACCEPTANCE"
    static let validIPAKey = "VEXSIGN_TEST_IPA_PATH"
    static let invalidIPAKey = "VEXSIGN_TEST_INVALID_IPA_PATH"

    /// Call from `setUpWithError()` of every hardware-dependent test class.
    static func requireHardware(file: StaticString = #filePath, line: UInt = #line) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip(
            "Hardware acceptance requires a physical iPhone. The current destination is a simulator, so no device claim is made.",
            file: file,
            line: line
        )
        #else
        guard ProcessInfo.processInfo.environment[optInKey] == "1" else {
            throw XCTSkip(
                "Set \(optInKey)=1 on a physical-device runner to execute hardware acceptance cases.",
                file: file,
                line: line
            )
        }
        #endif
    }

    /// A fixture path is supplied by the runner; the app never searches Documents
    /// for an arbitrary imported archive during a test.
    static func fixtureURL(for key: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else {
            throw XCTSkip("Set \(key) to a controlled fixture for this hardware case.", file: file, line: line)
        }
        return URL(fileURLWithPath: raw)
    }

    /// Attach the observed state without writing a screenshot that could include
    /// a user's library or a private path into a portable report.
    static func note(_ text: String, name: String) -> XCTAttachment {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
