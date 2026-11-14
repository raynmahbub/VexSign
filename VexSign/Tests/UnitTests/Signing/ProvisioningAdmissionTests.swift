import Security
import XCTest
import Zsign
@testable import VexSign

final class ProvisioningAdmissionTests: XCTestCase {
    private func metadata() throws -> Certificate {
        var value = try SigningRegressionFixture.profile()
        value.DeveloperCertificates = [SigningRegressionFixture.certificateDER]
        return value
    }

    func testMetadataSeamDoesNotAuthenticateRawPlistOrXMLWrappedInUnrelatedBytes() throws {
        let value = try metadata()
        XCTAssertNoThrow(try ProvisioningProfileParser.validateMetadata(value, now: SigningRegressionFixture.now))
        XCTAssertThrowsError(try ProvisioningProfileParser.validateMetadata(value, now: Date(timeIntervalSince1970: .nan)))
        let xml = try SigningRegressionFixture.unsignedProfileData(value)
        let binary = try PropertyListSerialization.data(fromPropertyList:
            try PropertyListSerialization.propertyList(from: xml, options: [], format: nil), format: .binary, options: 0)
        for data in [xml, binary, Data([0x30, 0x80]) + xml + Data([0, 0]), xml + Data([0xff]), Data()] {
            XCTAssertThrowsError(try ProvisioningProfileParser.parse(data, now: SigningRegressionFixture.now))
            XCTAssertNil(VexVerifyProvisioningProfileCMS(data, SigningRegressionFixture.now.timeIntervalSince1970))
        }
    }

    func testSelfSignedCMSIsNotAnAppleProvisioningSigner() throws {
        let cms = SigningRegressionFixture.cms
        XCTAssertNotNil(BundleSignature.certificateDERs(inCMS: cms), "The public fixture is structurally parseable CMS.")
        XCTAssertNil(VexVerifyProvisioningProfileCMS(cms, SigningRegressionFixture.now.timeIntervalSince1970))
        XCTAssertThrowsError(try ProvisioningProfileParser.parse(cms, now: SigningRegressionFixture.now))
        XCTAssertNil(VexVerifyProvisioningProfileCMS(cms + Data([0]), SigningRegressionFixture.now.timeIntervalSince1970))
        XCTAssertNil(VexVerifyProvisioningProfileCMS(cms, .nan))
        XCTAssertFalse(VexNativeSupportsSigningCertificate(SigningRegressionFixture.certificateDER))
    }

    func testRequiredProfileFieldsAndConsistencyAreStrict() throws {
        let valid = try metadata()
        let corruptions: [(inout Certificate) -> Void] = [
            { $0.UUID = "not-a-uuid" }, { $0.Name = " \n " }, { $0.TeamIdentifier = [] },
            { $0.TeamIdentifier = ["TOOSHORT"] }, { $0.TeamIdentifier = ["TESTTEAM00", "OTHERTEAM0"] },
            { $0.ApplicationIdentifierPrefix = nil }, { $0.ApplicationIdentifierPrefix = ["OTHER00000"] },
            { $0.Platform = [] }, { $0.Platform = ["iOS", "ios"] },
            { $0.ApplicationIdentifierPrefix = ["TESTTEAM00", "TESTTEAM00"] },
            { $0.DeveloperCertificates = [] }, { $0.DeveloperCertificates = [Data([1, 2, 3])] },
            { $0.DeveloperCertificates = [SigningRegressionFixture.certificateDER + Data([0])] },
            { $0.DeveloperCertificates = [SigningRegressionFixture.certificateDER, SigningRegressionFixture.certificateDER] },
            { $0.Entitlements = nil }, { $0.Entitlements?["application-identifier"] = AnyCodable("TESTTEAM00.com.*.invalid") },
            { $0.Entitlements?["com.apple.developer.team-identifier"] = AnyCodable("OTHERTEAM0") },
            { $0.CreationDate = $0.ExpirationDate },
        ]
        for (index, change) in corruptions.enumerated() {
            var value = valid; change(&value)
            XCTAssertThrowsError(try ProvisioningProfileParser.validateMetadata(value, now: SigningRegressionFixture.now), "corruption \(index)")
        }
    }

    func testExpiryAndFutureCreationRejectButDisplayPolicyDoesNotInventTrust() throws {
        var value = try metadata(); value.ExpirationDate = SigningRegressionFixture.now
        XCTAssertThrowsError(try ProvisioningProfileParser.validateMetadata(value, now: SigningRegressionFixture.now))
        XCTAssertNoThrow(try ProvisioningProfileParser.validateMetadata(value, now: SigningRegressionFixture.now, allowingExpiredForDisplay: true))
        XCTAssertThrowsError(try ProvisioningProfileParser.parse(SigningRegressionFixture.unsignedProfileData(value),
            now: SigningRegressionFixture.now, allowingExpiredForDisplay: true), "Display expiry policy must not bypass CMS authentication.")
        value = try metadata(); value.CreationDate = SigningRegressionFixture.now.addingTimeInterval(1)
        XCTAssertThrowsError(try ProvisioningProfileParser.validateMetadata(value, now: SigningRegressionFixture.now))
    }

    func testDeviceListsRejectConflictsDuplicatesAndInvalidValues() throws {
        let valid = try metadata()
        for devices in [["00008030-ABCDEF0123456789"], ["invalid device"],
                        ["00008030-ABCDEF0123456789", "00008030-abcdef0123456789"]] {
            var value = valid; value.ProvisionedDevices = devices
            // An all-devices profile cannot also claim a limited device list.
            XCTAssertThrowsError(try ProvisioningProfileParser.validateMetadata(value, now: SigningRegressionFixture.now))
        }
        var limited = valid; limited.ProvisionsAllDevices = false
        limited.ProvisionedDevices = ["00008030-ABCDEF0123456789"]
        XCTAssertNoThrow(try ProvisioningProfileParser.validateMetadata(limited, now: SigningRegressionFixture.now))
        limited.ProvisionedDevices = ["invalid device"]
        XCTAssertThrowsError(try ProvisioningProfileParser.validateMetadata(limited, now: SigningRegressionFixture.now))
    }

    func testMalformedAndUnavailablePKCS12HavePreciseFailureEvidence() {
        XCTAssertThrowsError(try SigningIdentityStore.inspect(Data([0x30, 0]), password: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not be opened"))
        }
        for data in [Data(), Data("not PKCS12".utf8), Data([0x30, 0])] {
            XCTAssertThrowsError(try SigningIdentityStore.inspect(data, password: "wrong"))
        }
        // A public certificate alone cannot prove possession of its private key.
        XCTAssertThrowsError(try SigningIdentityStore.inspect(SigningRegressionFixture.certificateDER, password: ""))
    }

    func testCertificateDatesAndDERMustBeFullyConsumedAndCalendarValid() throws {
        let original = SigningRegressionFixture.certificateDER
        XCTAssertNotNil(SigningIdentity(original))
        XCTAssertNil(SigningIdentity(original + Data([0])))
        var impossible = original
        let before = Data("261031234148Z".utf8)
        let range = try XCTUnwrap(impossible.range(of: before))
        impossible.replaceSubrange(range, with: Data("261332234148Z".utf8))
        XCTAssertNil(SigningIdentity(impossible), "Calendar normalization must not turn month 13/day 32 into a valid certificate date.")
        XCTAssertNil(DER.element([0x30, 0], at: Int.max))
        XCTAssertNil(DER.element([0x1f, 0], at: 0), "High-tag form is outside this bounded DER subset.")
    }

    func testProfileCacheCannotTurnAReplacedOrMalformedFileIntoTrustedInventory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-profile")
        var cache = ProvisioningProfileParser.Cache()
        try SigningRegressionFixture.unsignedProfileData(metadata()).write(to: file)
        XCTAssertThrowsError(try cache.read(file, now: SigningRegressionFixture.now))
        try Data("replacement".utf8).write(to: file)
        XCTAssertThrowsError(try cache.read(file, now: SigningRegressionFixture.now))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertThrowsError(try cache.read(file, now: SigningRegressionFixture.now))
    }

    private func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var length = Data()
        if content.count < 128 { length.append(UInt8(content.count)) }
        else {
            var value = content.count, bytes: [UInt8] = []
            while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
        }
        return Data([tag]) + length + content
    }

    private func changingCMSFields(_ change: ([Data]) throws -> [Data]) throws -> Data {
        let bytes = [UInt8](SigningRegressionFixture.cms)
        let outer = try XCTUnwrap(DER.element(bytes, at: 0))
        let info = try XCTUnwrap(DER.children(bytes, in: outer))
        let signed = try XCTUnwrap(DER.onlyChild(bytes, in: info[1]))
        let fields = try XCTUnwrap(DER.children(bytes, in: signed)).map { Data(DER.raw($0, in: bytes)) }
        let replacement = try change(fields).reduce(into: Data()) { $0 += $1 }
        return tlv(0x30, Data(DER.raw(info[0], in: bytes)) + tlv(0xa0, tlv(0x30, replacement)))
    }

    func testCMSSignerInfoIsRequiredAndCertificateSetOrderIsNotSignerIdentity() throws {
        let missingCertificates = try changingCMSFields { fields in fields.filter { $0.first != 0xa0 } }
        XCTAssertNil(BundleSignature.certificateDERs(inCMS: missingCertificates))
        let missingSigner = try changingCMSFields { fields in Array(fields.dropLast()) }
        XCTAssertNil(BundleSignature.certificateDERs(inCMS: missingSigner))
        let duplicateLeaf = try changingCMSFields { fields in
            fields.map { $0.first == 0xa0 ? self.tlv(0xa0, SigningRegressionFixture.certificateDER + SigningRegressionFixture.certificateDER) : $0 }
        }
        XCTAssertNil(BundleSignature.certificateDERs(inCMS: duplicateLeaf), "An ambiguous signer match is not resolved by SET order.")
        XCTAssertNil(BundleSignature.certificateDERs(inCMS: SigningRegressionFixture.cms + Data([0])))
    }
}
