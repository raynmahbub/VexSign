import XCTest
@testable import VexSign

/// The community catalogue publishes a calendar day (`yyyy-MM-dd`) and the app
/// derives expiry from it. Parsing has to be pinned to POSIX/Gregorian/UTC: a
/// device set to a non-Gregorian calendar would otherwise read a different year
/// from the same string, and a device east of UTC would expire a certificate a
/// day early.
final class NexCertsStatusTests: XCTestCase {
    func testCatalogueDayIsParsedAsMidnightUTC() throws {
        let parsed = try XCTUnwrap(NexCerts.Status._parseDay("2026-11-22"))
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_795_305_600, accuracy: 0.5)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: parsed)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 11)
        XCTAssertEqual(parts.day, 22)
        XCTAssertEqual(parts.hour, 0)
    }

    func testSurroundingWhitespaceIsAccepted() throws {
        let parsed = try XCTUnwrap(NexCerts.Status._parseDay(" 2026-01-02\n"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: parsed).day, 2)
    }

    /// A string the parser cannot read must not silently become "expired" or "today".
    func testMalformedDayIsRejected() {
        for text in ["", "not a date", "22/11/2026", "2026-13-40"] {
            XCTAssertNil(NexCerts.Status._parseDay(text), text)
        }
    }

    /// `valid_to` is published as an inclusive day: the certificate is still valid
    /// for the whole day it names, not until midnight UTC that morning.
    func testExpiryCoversTheWholePublishedDay() {
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        XCTAssertNotEqual(NexCerts.Status(apiValue: "signed", validTo: today), .expired)
        XCTAssertEqual(NexCerts.Status(apiValue: "signed", validTo: "2000-01-01"), .expired)
    }

    /// Revocation is only ever what the catalogue claims; expiry is derived locally, and
    /// a certificate whose published day has passed is expired whatever the licence says.
    func testExpiryIsDerivedLocallyAndRevocationIsWhateverTheCatalogueClaims() {
        XCTAssertEqual(NexCerts.Status(apiValue: "revoked", validTo: "2999-01-01"), .revoked)
        XCTAssertEqual(NexCerts.Status(apiValue: "signed", validTo: "2999-01-01"), .signed)
        XCTAssertEqual(NexCerts.Status(apiValue: "unknown", validTo: "2999-01-01"), .unknown)
        XCTAssertEqual(NexCerts.Status(apiValue: "signed", validTo: "2000-01-01"), .expired)
        XCTAssertEqual(NexCerts.Status(apiValue: "✅", validTo: "2000-01-01"), .expired)
    }

    /// An unreadable day must not be read as "never expires" *or* "long expired": the
    /// catalogue's own claim is all that is left, so the badge still renders.
    func testUnreadableDayFallsBackToTheCatalogueClaim() {
        XCTAssertEqual(NexCerts.Status(apiValue: "signed", validTo: ""), .signed)
        XCTAssertEqual(NexCerts.Status(apiValue: "revoked", validTo: "not a date"), .revoked)
        XCTAssertEqual(NexCerts.Status(apiValue: "unknown", validTo: "not a date"), .unknown)
    }
}
