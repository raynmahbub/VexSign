import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

final class ConsentedAnisetteProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func provider(_ revision: String = "1") throws -> AnisetteProviderDescriptor {
        try AnisetteProviderDescriptor(identifier: "fixture", displayName: "Fixture", policyRevision: revision,
                                       endpoint: URL(string: "https://provider.example.invalid/anisette"))
    }

    func testRemoteDescriptorRejectsInsecureOrSecretBearingEndpoints() throws {
        for text in ["http://example.invalid", "https://user:secret@example.invalid", "https://example.invalid/?key=secret", "https://example.invalid/#secret"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertThrowsError(try AnisetteProviderDescriptor(identifier: "fixture", displayName: "Fixture", policyRevision: "1", endpoint: url)) {
                XCTAssertEqual($0 as? AnisetteConsentError, .invalidProvider)
            }
        }
        _ = try provider()
    }

    func testGrantIsBoundToProviderPolicyAndGateInstance() throws {
        var gate = AnisetteConsentGate()
        let descriptor = try provider()
        let token = try gate.recordExplicitConsent(for: descriptor, now: now)
        XCTAssertNoThrow(try gate.require(token, provider: descriptor, now: now))
        XCTAssertThrowsError(try gate.require(token, provider: provider("2"), now: now)) {
            XCTAssertEqual($0 as? AnisetteConsentError, .providerChanged)
        }
        XCTAssertThrowsError(try AnisetteConsentGate().require(token, provider: descriptor, now: now)) {
            XCTAssertEqual($0 as? AnisetteConsentError, .consentRequired)
        }
    }

    func testExpiredReplacedAndRevokedGrantsCannotBeReused() throws {
        let descriptor = try provider()
        var gate = AnisetteConsentGate()
        let old = try gate.recordExplicitConsent(for: descriptor, now: now, lifetime: 10)
        XCTAssertThrowsError(try gate.require(old, provider: descriptor, now: now.addingTimeInterval(10)))
        let current = try gate.recordExplicitConsent(for: descriptor, now: now)
        XCTAssertThrowsError(try gate.require(old, provider: descriptor, now: now))
        gate.revoke()
        XCTAssertThrowsError(try gate.require(current, provider: descriptor, now: now))
    }

    func testLifetimeMustBeFinitePositiveAndAtMostFifteenMinutes() throws {
        var gate = AnisetteConsentGate()
        let descriptor = try provider()
        let lifetimes: [TimeInterval] = [0, -1, 901, .infinity, .nan]
        for lifetime in lifetimes {
            XCTAssertThrowsError(try gate.recordExplicitConsent(for: descriptor, now: now, lifetime: lifetime)) {
                XCTAssertEqual($0 as? AnisetteConsentError, .invalidLifetime)
            }
        }
    }
}
