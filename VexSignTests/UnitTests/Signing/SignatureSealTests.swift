import CryptoKit
import XCTest
import Zsign
@testable import VexSign

/// Low-level cryptographic verification with a synthetic NON-APPLE signer. This
/// deliberately proves no profile trust, Keychain ownership, or installation.
final class SignatureSealTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SealTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        root = nil
    }

    private struct Fixture {
        let executable: Data
        let certificate: Data
        let identifier: String
        let team: String
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: SignatureSealTests.self).url(forResource: "CodeSignatureCMSFixture", withExtension: "json"),
            "The public-only JSON fixture must be in the synchronized XCTest resources.")
        let dictionary = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return Fixture(executable: try XCTUnwrap(Data(base64Encoded: XCTUnwrap(dictionary["executable"]))),
            certificate: try XCTUnwrap(Data(base64Encoded: XCTUnwrap(dictionary["certificate"]))),
            identifier: try XCTUnwrap(dictionary["identifier"]), team: try XCTUnwrap(dictionary["team"]))
    }

    private func file(_ data: Data, name: String = UUID().uuidString) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url); return url
    }

    private func verify(_ fixture: Fixture, bytes: Data? = nil, fingerprint: String? = nil,
                        entitlements: [String: Any] = [:], info: Data? = nil) throws -> SigningIdentity {
        try SignatureVerifier.verifyExecutable(at: file(bytes ?? fixture.executable), identifier: fixture.identifier,
            team: fixture.team, certificateFingerprint: fingerprint ?? SigningIdentity.fingerprint(of: fixture.certificate),
            entitlements: entitlements, info: info, resources: nil, expectsApplication: true,
            now: SigningRegressionFixture.now)
    }

    func testExactPublicFixtureVerifiesEveryDirectoryPageSlotAndActualSigner() throws {
        let value = try fixture(), signer = try verify(value)
        XCTAssertEqual(signer.fingerprint, SigningIdentity.fingerprint(of: value.certificate))
        XCTAssertEqual(signer.teamIdentifier, value.team)
        XCTAssertFalse(VexNativeSupportsSigningCertificate(value.certificate), "It is intentionally not a production Apple signing identity.")
        let image = try XCTUnwrap(MachOEntitlements.images(in: value.executable).first)
        let cms = try XCTUnwrap(image.blobs[0x10000])
        XCTAssertEqual(VexVerifyCodeSignatureCMS(Data(cms.dropFirst(8)), try XCTUnwrap(image.blobs[0]), image.blobs[0x1000]), value.certificate)
    }

    func testAChangedExecutablePageCannotRetainAValidCMS() throws {
        let value = try fixture(); var bytes = value.executable
        bytes[1024] ^= 1
        XCTAssertThrowsError(try verify(value, bytes: bytes))
    }

    func testEveryFatImageIsVerifiedInBothTableFormatsAndByteOrders() throws {
        let value = try fixture()
        for wide in [false, true] { for big in [false, true] {
            let fat = SigningRegressionFixture.fat([value.executable, value.executable], wide: wide, big: big)
            XCTAssertNoThrow(try verify(value, bytes: fat))
            var altered = value.executable; altered[1025] ^= 1
            let hiddenBadSlice = SigningRegressionFixture.fat([value.executable, altered], wide: wide, big: big)
            XCTAssertThrowsError(try verify(value, bytes: hiddenBadSlice), "A valid first image cannot hide a tampered second image.")
        } }
    }

    func testCMSAuthenticatesTheAlternateDirectoryNotOnlyThePrimary() throws {
        let value = try fixture(), image = try XCTUnwrap(MachOEntitlements.images(in: value.executable).first)
        let cms = Data(try XCTUnwrap(image.blobs[0x10000]).dropFirst(8))
        let primary = try XCTUnwrap(image.blobs[0]); var alternate = try XCTUnwrap(image.blobs[0x1000])
        alternate[alternate.count - 1] ^= 1
        XCTAssertNil(VexVerifyCodeSignatureCMS(cms, primary, alternate))
        var wrongPrimary = primary; wrongPrimary[wrongPrimary.count - 1] ^= 1
        XCTAssertNil(VexVerifyCodeSignatureCMS(cms, wrongPrimary, image.blobs[0x1000]))
        XCTAssertNil(VexVerifyCodeSignatureCMS(cms + Data([0]), primary, image.blobs[0x1000]))
    }

    func testCorrectCMSCannotSubstituteAnUnexpectedSignerOrEntitlementPlan() throws {
        let value = try fixture()
        XCTAssertThrowsError(try verify(value, fingerprint: "different-public-certificate"))
        XCTAssertThrowsError(try verify(value, entitlements: ["dynamic-codesigning": true]))
        XCTAssertThrowsError(try verify(value, info: Data("unsealed replacement metadata".utf8)))
    }

    func testChangedRequirementEntitlementAndSignatureBlobsReject() throws {
        let value = try fixture(), image = try XCTUnwrap(MachOEntitlements.images(in: value.executable).first)
        for slot in [UInt32(2), 5, 7, 0x10000] {
            var bytes = value.executable
            let blob = try XCTUnwrap(image.blobs[slot]), range = try XCTUnwrap(bytes.range(of: blob))
            bytes[range.upperBound - 1] ^= 1
            XCTAssertThrowsError(try verify(value, bytes: bytes), "changed slot \(slot)")
        }
    }

    func testCodeDirectoryHeaderAndHashBoundsRejectBeforeAnyUnsafeSlice() throws {
        let value = try fixture(), image = try XCTUnwrap(MachOEntitlements.images(in: value.executable).first)
        let original = try XCTUnwrap(image.blobs[0x1000])
        let special = image.blobs.filter { [UInt32(2), 5, 7].contains($0.key) }
        XCTAssertEqual(try SignatureVerifier.verifyDirectory(original, executable: value.executable, prefix: 0..<4096,
            identifier: value.identifier, team: value.team, special: special, textLimit: 4096, executionFlags: 1), 2)
        for offset in [4, 8, 12, 16, 20, 24, 28, 32, 36, 37, 39, 48, 72, 80] {
            var changed = original; changed[offset] ^= 0xff
            XCTAssertThrowsError(try SignatureVerifier.verifyDirectory(changed, executable: value.executable, prefix: 0..<4096,
                identifier: value.identifier, team: value.team, special: special, textLimit: 4096, executionFlags: 1), "header offset \(offset)")
        }
    }

    func testCanonicalDEROnlyEntitlementsAreReadableWithoutAnXMLFallback() throws {
        let der = Data([0x31, 0x10, 0x30, 0x06, 0x0c, 0x01, 0x61, 0x01, 0x01, 0x00,
                        0x30, 0x06, 0x0c, 0x01, 0x7a, 0x02, 0x01, 0x00])
        let data = try SigningRegressionFixture.machO(rawBlobs: [(7, SigningRegressionFixture.blob(0xfade7172, payload: der))])
        let values = try MachOEntitlements.requiredEntitlements(in: data)
        XCTAssertTrue(MachOEntitlements.equivalent(values, ["a": false, "z": 0]))
        XCTAssertFalse(MachOEntitlements.equivalent(values, ["a": 0, "z": false]))
    }

    func testNonCanonicalDERAndXMLDERDisagreementNeverFallBackToTheConvenientView() throws {
        let canonical = Data([0x31, 0x0b, 0x30, 0x09, 0x0c, 0x04, 0x66, 0x6c, 0x61, 0x67, 0x01, 0x01, 0x00])
        let xml = SigningRegressionFixture.blob(0xfade7171, payload: try SigningRegressionFixture.plist(["flag": true]))
        let conflict = try SigningRegressionFixture.machO(rawBlobs: [(5, xml), (7, SigningRegressionFixture.blob(0xfade7172, payload: canonical))])
        XCTAssertThrowsError(try MachOEntitlements.requiredEntitlements(in: conflict))
        var badBoolean = canonical; badBoolean[badBoolean.count - 1] = 1
        for der in [badBoolean, canonical + Data([0]), Data([0x31, 0x80, 0, 0]), Data([0x30, 0]), Data([0x31, 3, 4, 1, 0])] {
            XCTAssertThrowsError(try MachOEntitlements.decodeDEREntitlements(der))
        }
    }

    func testDifferingSliceCapabilitiesAreAmbiguousRatherThanTakenFromTheFirstSlice() throws {
        let one = try SigningRegressionFixture.machO(entitlements: ["flag": true])
        let two = try SigningRegressionFixture.machO(entitlements: ["flag": false])
        XCTAssertThrowsError(try MachOEntitlements.requiredEntitlements(in: SigningRegressionFixture.fat([one, two]))) { error in
            guard case MachOEntitlements.InspectionFailure.differentSlices = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    private func resourceBundle() throws -> (URL, URL) {
        let bundle = root.appendingPathComponent("Resources.app")
        try SigningRegressionFixture.bundle(at: bundle)
        try Data("original resource bytes".utf8).write(to: bundle.appendingPathComponent("document.dat"))
        return (bundle, bundle.appendingPathComponent("Fixture"))
    }

    private func sealResources(_ bundle: URL, excluding: Set<String> = []) throws -> Data {
        var files: [String: Any] = [:], files2: [String: Any] = [:]
        for name in ["Info.plist", "document.dat"] where !excluding.contains(name) {
            let bytes = try Data(contentsOf: bundle.appendingPathComponent(name))
            files[name] = Data(Insecure.SHA1.hash(data: bytes))
            if name != "Info.plist" {
                files2[name] = ["hash": Data(Insecure.SHA1.hash(data: bytes)), "hash2": Data(SHA256.hash(data: bytes))]
            }
        }
        let data = try SigningRegressionFixture.plist(["files": files, "files2": files2,
            "rules2": ["^.*$": ["omit": true]]]) // An arbitrary omit rule must not hide a fresh-run file.
        try data.write(to: bundle.appendingPathComponent("_CodeSignature/CodeResources")); return data
    }

    func testResourceSealsCheckEveryRegularFileAndBothHashAlgorithms() throws {
        let (bundle, executable) = try resourceBundle(), expected = try sealResources(bundle)
        var cache: [URL: SignatureVerifier.ResourceHashes] = [:]
        XCTAssertEqual(try SignatureVerifier.verifyResources(in: bundle, executable: executable, cache: &cache), expected)
        XCTAssertEqual(cache.count, 2)
        try Data("tampered resource".utf8).write(to: bundle.appendingPathComponent("document.dat"))
        cache.removeAll() // Independent verification run, not a stale run-owned cache.
        XCTAssertThrowsError(try SignatureVerifier.verifyResources(in: bundle, executable: executable, cache: &cache))
    }

    func testResourceRulesCannotHideOmittedAddedMissingOrLinkedFiles() throws {
        let (bundle, executable) = try resourceBundle()
        var cache: [URL: SignatureVerifier.ResourceHashes] = [:]
        _ = try sealResources(bundle, excluding: ["document.dat"])
        XCTAssertThrowsError(try SignatureVerifier.verifyResources(in: bundle, executable: executable, cache: &cache))
        _ = try sealResources(bundle); cache.removeAll()
        let added = bundle.appendingPathComponent("unsealed.dat"); try Data([1]).write(to: added)
        XCTAssertThrowsError(try SignatureVerifier.verifyResources(in: bundle, executable: executable, cache: &cache))
        try FileManager.default.removeItem(at: added); try FileManager.default.removeItem(at: bundle.appendingPathComponent("document.dat")); cache.removeAll()
        XCTAssertThrowsError(try SignatureVerifier.verifyResources(in: bundle, executable: executable, cache: &cache))
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("document.dat"), withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertThrowsError(try SignatureVerifier.verifyResources(in: bundle, executable: executable, cache: &cache))
    }
}
