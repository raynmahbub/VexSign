import Foundation
import XCTest
import SideSign
@testable import NativeSigningLinkSmoke

final class SideSignSessionCodecTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func anisette(_ marker: String = "fresh") -> AnisetteData {
        AnisetteData(machineID: marker + "-machine", oneTimePassword: marker + "-anisette-otp",
                     localUserID: "local", routingInfo: "route", deviceID: "device", serialNumber: "serial",
                     clientInfo: "client", userAgent: "agent", clientTime: "time", locale: "en_US", timeZone: "UTC")
    }

    private func session() -> AuthSession {
        AuthSession(account: Account(appleID: "fixture@example.invalid", identifier: "123",
                                     firstName: "PRIVATE-FIRST", lastName: "PRIVATE-LAST"),
                    session: Session(dsid: "123", authToken: "SYNTHETIC-TOKEN", anisetteData: anisette("old"),
                                     xcodeVersion: "26.2", creationDate: now.addingTimeInterval(-10),
                                     expirationDate: now.addingTimeInterval(60), timeToLive: 70))
    }

    private func modifiedSession(_ update: (inout Session) -> Void) -> AuthSession {
        let original = session()
        var sdkSession = original.session
        update(&sdkSession)
        return AuthSession(account: original.account, session: sdkSession)
    }

    private func restore(_ data: Data, at date: Date? = nil) throws -> AuthSession {
        try SideSignSessionCodec.decodeForRevalidation(data, freshAnisetteData: anisette(), now: date ?? now)
    }

    private func changed(_ data: Data, key: String, value: Any) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json[key] = value
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testRoundTripPersistsAllowlistAndRequiresReplacementAnisette() throws {
        let data = try SideSignSessionCodec.encode(session(), now: now)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["machinePassword", "anisetteData", "old-machine", "old-anisette-otp", "PRIVATE-FIRST", "PRIVATE-LAST"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        let candidate = try restore(data)
        XCTAssertEqual(candidate.session.authToken, "SYNTHETIC-TOKEN")
        XCTAssertEqual(candidate.account.identifier, "123")
        XCTAssertEqual(candidate.account.firstName, "")
        XCTAssertEqual(candidate.session.anisetteData, anisette())
        XCTAssertNil(candidate.session.machinePassword)
    }

    func testUnknownVersionSDKAndUnexpectedFieldsAreRejected() throws {
        let data = try SideSignSessionCodec.encode(session(), now: now)
        for (key, value) in [("schema", 2 as Any), ("sdkRevision", "unreviewed" as Any)] {
            XCTAssertThrowsError(try restore(changed(data, key: key, value: value))) {
                XCTAssertEqual($0 as? SideSignSessionCodecError, .unsupportedVersion)
            }
        }
        XCTAssertThrowsError(try restore(changed(data, key: "password", value: "not-allowed"))) {
            XCTAssertEqual($0 as? SideSignSessionCodecError, .malformedRecord)
        }
    }

    func testExpiredSessionIsRejectedOnEncodeAndDecode() throws {
        let value = modifiedSession { $0.expirationDate = now }
        XCTAssertThrowsError(try SideSignSessionCodec.encode(value, now: now)) {
            XCTAssertEqual($0 as? SideSignSessionCodecError, .expired)
        }
        let data = try SideSignSessionCodec.encode(session(), now: now)
        XCTAssertThrowsError(try restore(data, at: now.addingTimeInterval(60))) {
            XCTAssertEqual($0 as? SideSignSessionCodecError, .expired)
        }
    }

    func testUnknownExpiryRequiresReauthenticationRatherThanUnlimitedValidity() throws {
        let value = modifiedSession {
            $0.expirationDate = nil
            $0.timeToLive = nil
        }
        XCTAssertThrowsError(try SideSignSessionCodec.encode(value, now: now)) {
            XCTAssertEqual($0 as? SideSignSessionCodecError, .unknownExpiry)
        }
    }

    func testMachinePasswordIsRejectedNotSilentlyDropped() throws {
        let value = modifiedSession { $0.machinePassword = "synthetic-unreviewed-material" }
        XCTAssertThrowsError(try SideSignSessionCodec.encode(value, now: now)) {
            XCTAssertEqual($0 as? SideSignSessionCodecError, .unsupportedMachinePassword)
        }
    }

    func testTTLBoundsExpiryAndSupportsMissingExplicitExpiry() throws {
        let value = modifiedSession {
            $0.expirationDate = now.addingTimeInterval(500)
            $0.timeToLive = 30
        }
        var candidate = try restore(SideSignSessionCodec.encode(value, now: now))
        XCTAssertEqual(candidate.session.expirationDate, now.addingTimeInterval(20))
        let withoutExpiry = modifiedSession {
            $0.expirationDate = nil
            $0.timeToLive = 30
        }
        candidate = try restore(SideSignSessionCodec.encode(withoutExpiry, now: now))
        XCTAssertEqual(candidate.session.expirationDate, now.addingTimeInterval(20))
    }

    func testMalformedEmptyOversizedAndMissingFieldsAreRejected() throws {
        for data in [Data(), Data(repeating: 0, count: SideSignSessionCodec.maximumBytes + 1)] {
            XCTAssertThrowsError(try restore(data)) {
                XCTAssertEqual($0 as? SideSignSessionCodecError, .invalidSize)
            }
        }
        for text in ["not JSON", "[]", "{}"] {
            XCTAssertThrowsError(try restore(Data(text.utf8))) {
                XCTAssertEqual($0 as? SideSignSessionCodecError, .malformedRecord)
            }
        }
        let data = try SideSignSessionCodec.encode(session(), now: now)
        XCTAssertThrowsError(try restore(changed(data, key: "authToken", value: " "))) {
            XCTAssertEqual($0 as? SideSignSessionCodecError, .invalidFields)
        }
    }

    func testInvalidDatesTTLAndReplacementHeadersAreRejected() throws {
        let invalidTTL = modifiedSession { $0.timeToLive = -.infinity }
        XCTAssertThrowsError(try SideSignSessionCodec.encode(invalidTTL, now: now))
        let futureCreation = modifiedSession { $0.creationDate = now.addingTimeInterval(1) }
        XCTAssertThrowsError(try SideSignSessionCodec.encode(futureCreation, now: now))
        let data = try SideSignSessionCodec.encode(session(), now: now)
        var headers = anisette()
        headers.oneTimePassword = ""
        XCTAssertThrowsError(try SideSignSessionCodec.decodeForRevalidation(data, freshAnisetteData: headers, now: now)) {
            XCTAssertEqual($0 as? SideSignSessionCodecError, .invalidFields)
        }
    }
}
