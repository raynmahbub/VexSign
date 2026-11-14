import XCTest
import Security
@testable import VexSign

/// Pure generation tests: no production Keychain record is read or modified.
final class DeviceTLSIdentityTests: XCTestCase {
    private func verify(_ identity: DeviceTLSIdentity.Identity, host: String) throws -> Bool {
        let leaf = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.leafCertificate as CFData))
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.rootCertificate as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates([leaf, root] as CFArray,
            SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
        let value = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(value, [root] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(value, true), errSecSuccess)
        XCTAssertEqual(SecTrustSetNetworkFetchAllowed(value, false), errSecSuccess)
        return SecTrustEvaluateWithError(value, nil)
    }

    func testGeneratedChainWorksForLoopbackWithoutNetwork() throws {
        let identity = try DeviceTLSIdentity.generate()
        XCTAssertTrue(try verify(identity, host: "127.0.0.1"))
        XCTAssertTrue(try verify(identity, host: "localhost"))
        XCTAssertFalse(try verify(identity, host: "other.example.invalid"))
        XCTAssertGreaterThan(identity.rootExpiry, identity.leafExpiry)
    }

    func testEachDeviceGetsDifferentKeysAndCA() throws {
        let first = try DeviceTLSIdentity.generate()
        let second = try DeviceTLSIdentity.generate()
        XCTAssertNotEqual(first.rootKey, second.rootKey)
        XCTAssertNotEqual(first.rootCertificate, second.rootCertificate)
        XCTAssertNotEqual(first.leafKey, second.leafKey)
    }

    func testGeneratedLeafIncludesTheWebManagerLANAddressInItsSAN() throws {
        let identity = try DeviceTLSIdentity.generate(serverNames: ["127.0.0.1", "localhost", "192.168.1.20"])
        XCTAssertTrue(try verify(identity, host: "192.168.1.20"))
        XCTAssertFalse(try verify(identity, host: "192.168.1.21"))
        XCTAssertEqual(identity.serverNames ?? [], ["127.0.0.1", "192.168.1.20", "localhost"])
    }

    func testLeafReissueAddsLANNameWithoutChangingThePinnedCA() throws {
        let saved = try DeviceTLSIdentity.generate()
        let renewed = try DeviceTLSIdentity.renew(saved, serverNames: ["127.0.0.1", "localhost", "192.168.1.20"])
        XCTAssertEqual(saved.rootCertificate, renewed.rootCertificate)
        XCTAssertEqual(saved.rootKey, renewed.rootKey)
        XCTAssertTrue(try verify(renewed, host: "192.168.1.20"))
    }

    func testLeafRenewalPreservesTrustedCA() throws {
        let saved = try DeviceTLSIdentity.generate()
        let renewed = try DeviceTLSIdentity.renew(saved)
        XCTAssertEqual(saved.rootKey, renewed.rootKey)
        XCTAssertEqual(saved.rootCertificate, renewed.rootCertificate)
        XCTAssertEqual(saved.rootExpiry, renewed.rootExpiry)
        XCTAssertNotEqual(saved.leafKey, renewed.leafKey)
        XCTAssertNotEqual(saved.leafCertificate, renewed.leafCertificate)
        XCTAssertTrue(try verify(renewed, host: "127.0.0.1"))
    }

    func testExpiredCARequiresExplicitRotation() throws {
        var identity = try DeviceTLSIdentity.generate()
        identity.rootExpiry = Date().addingTimeInterval(-1)
        XCTAssertThrowsError(try DeviceTLSIdentity.renew(identity))
    }

    func testIdentitySerializationPreservesCA() throws {
        let identity = try DeviceTLSIdentity.generate()
        let restored = try JSONDecoder().decode(DeviceTLSIdentity.Identity.self,
            from: JSONEncoder().encode(identity))
        XCTAssertEqual(restored.rootCertificate, identity.rootCertificate)
        XCTAssertEqual(restored.rootKey, identity.rootKey)
        XCTAssertTrue(try verify(restored, host: "127.0.0.1"))
    }

    func testDERLengthEncodingBoundaries() {
        XCTAssertEqual(Array(DeviceTLSIdentity.der(4, Data(repeating: 0, count: 127)).prefix(2)), [4, 127])
        XCTAssertEqual(Array(DeviceTLSIdentity.der(4, Data(repeating: 0, count: 128)).prefix(3)), [4, 0x81, 128])
        XCTAssertEqual(Array(DeviceTLSIdentity.der(4, Data(repeating: 0, count: 256)).prefix(4)), [4, 0x82, 1, 0])
    }
}
