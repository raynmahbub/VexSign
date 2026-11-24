import XCTest
@testable import VexSign

final class SigningAuthorizationMismatchTests: XCTestCase {
    private let baseline = SigningResolutionAuthorization(
        fingerprint: "complete-a",
        plannedRemovals: [],
        sourceFingerprint: "source-a",
        componentFingerprint: "components-a",
        identityFingerprint: "identity-a",
        profileFingerprint: "profile-a",
        requiredCapabilitiesFingerprint: "capabilities-a",
        deviceFingerprint: "device-a"
    )

    func testUnchangedAuthorizationMatchesAndMissingAuthorizationIsDistinct() {
        XCTAssertNil(baseline.mismatch(against: baseline))
        XCTAssertEqual(baseline.mismatch(against: nil), .authorizationMissing)
    }

    func testAuthorizationMismatchIdentifiesWhichReviewedInputChanged() {
        XCTAssertEqual(baseline.mismatch(against: changed(source: "source-b")), .sourceBundle)
        XCTAssertEqual(baseline.mismatch(against: changed(removals: ["PlugIns/Share.appex"])), .optionalRemovals)
        XCTAssertEqual(baseline.mismatch(against: changed(components: "components-b")), .componentPlan)
        XCTAssertEqual(baseline.mismatch(against: changed(identity: "identity-b")), .signingIdentity)
        XCTAssertEqual(baseline.mismatch(against: changed(profile: "profile-b")), .provisioningProfile)
        XCTAssertEqual(baseline.mismatch(against: changed(capabilities: "capabilities-b")), .requiredCapabilities)
        XCTAssertEqual(baseline.mismatch(against: changed(device: "device-b")), .targetDevice)
        XCTAssertEqual(baseline.mismatch(against: changed(fingerprint: "complete-b")), .other)
    }

    private func changed(
        fingerprint: String = "complete-b",
        source: String = "source-a",
        removals: [String] = [],
        components: String = "components-a",
        identity: String = "identity-a",
        profile: String = "profile-a",
        capabilities: String = "capabilities-a",
        device: String = "device-a"
    ) -> SigningResolutionAuthorization {
        .init(fingerprint: fingerprint, plannedRemovals: removals, sourceFingerprint: source,
            componentFingerprint: components, identityFingerprint: identity, profileFingerprint: profile,
            requiredCapabilitiesFingerprint: capabilities, deviceFingerprint: device)
    }
}
