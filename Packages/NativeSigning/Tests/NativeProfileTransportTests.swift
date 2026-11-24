import Foundation
import XCTest
@testable import NativeSigningLinkSmoke

/// DTO/selection fixtures only: no real HTTP, CMS verification or Apple mutation.
final class NativeProfileTransportTests: XCTestCase {
    private static let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
    private static func request(expectedUUID: UUID? = nil) throws -> NativeProfileCreationRequest {
        let validation = try NativeProfileValidationRequest(teamIdentifier: "ABCDE12345", bundleIdentifier: "com.example.fixture",
            deviceIdentifier: "0000ABCD-0011223344556677", certificateDER: Data([1]), expectedUUID: expectedUUID)
        return try .init(identityID: UUID(), validation: validation, appID: "APP1", deviceID: "DEVICE1", certificateID: "CERT1")
    }
    private static func listing(id: String = "PROFILE1", appID: String = "APP1", bundle: String = "com.example.fixture", uuid: UUID = NativeProfileTransportTests.uuid) throws -> VexSignProfileListing {
        let fields: [String: Any] = ["provisioningProfileId": id, "UUID": uuid.uuidString,
                                    "appId": ["appIdId": appID, "identifier": bundle]]
        return try JSONDecoder().decode(VexSignProfileListing.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    private static func download(id: String = "PROFILE1", uuid: UUID = NativeProfileTransportTests.uuid, cms: Data = Data([1, 2, 3])) throws -> VexSignDownloadedProfile {
        let fields = ["provisioningProfileId": id, "UUID": uuid.uuidString, "encodedProfile": cms.base64EncodedString()]
        return try JSONDecoder().decode(VexSignDownloadedProfile.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testMatchingCandidatesRequireExactAppIDAndBundle() throws {
        let rows = try SideSignProfileInventoryPolicy.candidates([Self.listing()], request: Self.request())
        XCTAssertEqual(rows.count, 1)
        let unrelated = try Self.listing(appID: "OTHER", bundle: "com.other.app")
        XCTAssertTrue(try SideSignProfileInventoryPolicy.candidates([unrelated], request: Self.request()).isEmpty)
    }

    func testRemoteAliasOrCaseMismatchCannotHideExistingTarget() throws {
        for row in [try Self.listing(appID: "OTHER"), try Self.listing(bundle: "com.example.Fixture"), try Self.listing(bundle: "com.other.app")] {
            XCTAssertThrowsError(try SideSignProfileInventoryPolicy.candidates([row], request: Self.request())) {
                XCTAssertEqual($0 as? NativeProfileCreationError, .inventoryRejected)
            }
        }
    }

    func testUnrelatedWildcardIsNotAnExplicitProfileMatch() throws {
        let row = try Self.listing(appID: "OTHER", bundle: "com.example.*")
        XCTAssertTrue(try SideSignProfileInventoryPolicy.candidates([row], request: Self.request()).isEmpty)
    }

    func testDuplicateProfileIDsOrUUIDsFailClosed() throws {
        let first = try Self.listing()
        XCTAssertThrowsError(try SideSignProfileInventoryPolicy.candidates([first, Self.listing(uuid: UUID())], request: Self.request()))
        XCTAssertThrowsError(try SideSignProfileInventoryPolicy.candidates([first, Self.listing(id: "PROFILE2")], request: Self.request()))
    }

    func testDownloadIDAndUUIDMustMatchListingBeforeCMSValidation() throws {
        let listing = try Self.listing()
        for bad in [try Self.download(id: "OTHER"), try Self.download(uuid: UUID()), try Self.download(cms: Data())] {
            XCTAssertThrowsError(try SideSignProfileInventoryPolicy.observation(bad, listing: listing))
        }
        let observation = try SideSignProfileInventoryPolicy.observation(Self.download(), listing: listing)
        XCTAssertEqual(observation.listedUUID, Self.uuid)
        XCTAssertEqual(observation.cms, Data([1, 2, 3]))
        XCTAssertEqual(observation.description, "NativeProfileObservation(redacted)")
        // This raw observation is intentionally NOT an authenticated profile.
    }

    func testMissingListBindingsAndDownloadCMSDoNotDefault() throws {
        for fields in [["provisioningProfileId": "PROFILE1"], ["UUID": Self.uuid.uuidString]] {
            XCTAssertThrowsError(try JSONDecoder().decode(VexSignProfileListing.self, from: JSONSerialization.data(withJSONObject: fields)))
        }
        let fields = ["provisioningProfileId": "PROFILE1", "UUID": Self.uuid.uuidString]
        XCTAssertThrowsError(try JSONDecoder().decode(VexSignDownloadedProfile.self, from: JSONSerialization.data(withJSONObject: fields)))
    }

    func testExplicitExistingUUIDSelectsOnlyThatCandidate() throws {
        let selected = UUID()
        let rows = try SideSignProfileInventoryPolicy.candidates([Self.listing(), Self.listing(id: "PROFILE2", uuid: selected)], request: Self.request(expectedUUID: selected))
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.uuid, selected)
    }

    func testOversizeCMSAndMalformedRemoteIDAreRejected() throws {
        XCTAssertThrowsError(try SideSignProfileInventoryPolicy.observation(Self.download(cms: Data(repeating: 0, count: 1024 * 1024 + 1)), listing: Self.listing()))
        XCTAssertThrowsError(try SideSignProfileInventoryPolicy.candidates([Self.listing(id: "bad/id")], request: Self.request()))
    }
}
