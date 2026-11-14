//
//  OCSPTests.swift
//  VexSignTests
//
//  the revocation evidence VexSign can check itself.
//
//  The fixtures are built with the same DER writer the request uses, then parsed back. That proves
//  the parser against the encoder — not against Apple's live responder, which no test here can
//  reach. A parser tested only with a captured Apple response would break the day Apple adds a
//  field; a parser tested against a structure this repo controls is at least held to the spec it
//  claims to implement.
//

import Foundation
import XCTest
@testable import VexSign

final class OCSPTests: XCTestCase {
	private let serial = Data([0x01, 0x23, 0x45])

	// MARK: - DER

	func testTLVRoundTrip() throws {
		let encoded = ASN1.sequence([ASN1.integer(258), ASN1.octetString(Data([1, 2, 3]))])
		let parsed = try XCTUnwrap(ASN1.parse(encoded))

		XCTAssertEqual(parsed.tag, ASN1.tagSequence)
		XCTAssertEqual(parsed.children.count, 2)
		XCTAssertEqual(Array(parsed.children[0].content), [0x01, 0x02])
		XCTAssertEqual(Array(parsed.children[1].content), [1, 2, 3])
	}

	func testLongFormLengths() throws {
		let payload = Data(repeating: 0xAB, count: 300)
		let encoded = ASN1.octetString(payload)

		XCTAssertEqual(encoded[0], ASN1.tagOctetString)
		XCTAssertEqual(encoded[1], 0x82) // two length bytes

		let parsed = try XCTUnwrap(ASN1.parse(encoded))
		XCTAssertEqual(parsed.content.count, 300)
	}

	func testIntegerIsMinimalAndKeepsTheHighBitClear() throws {
		// 0x80 alone would read as a negative number, so DER requires a leading zero.
		let encoded = ASN1.integer(magnitude: Data([0x80]))
		XCTAssertEqual(Array(encoded), [0x02, 0x02, 0x00, 0x80])

		// Leading zeros in the magnitude are dropped.
		let trimmed = ASN1.integer(magnitude: Data([0x00, 0x00, 0x01]))
		XCTAssertEqual(Array(trimmed), [0x02, 0x01, 0x01])
	}

	func testContextTags() throws {
		let encoded = ASN1.explicit(0, ASN1.octetString(Data([9])))
		let parsed = try XCTUnwrap(ASN1.parse(encoded))

		XCTAssertEqual(parsed.contextNumber, 0)
		XCTAssertTrue(parsed.isConstructed)
		XCTAssertEqual(parsed.children.first?.tag, ASN1.tagOctetString)
	}

	func testGeneralizedTimeRoundTrip() throws {
		let date = Date(timeIntervalSince1970: 1_800_000_000)
		let parsed = try XCTUnwrap(ASN1.parse(ASN1.generalizedTime(date)))
		let decoded = try XCTUnwrap(ASN1.parseGeneralizedTime(parsed))

		XCTAssertEqual(decoded.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
	}

	func testTruncatedInputIsRejectedRatherThanHalfParsed() {
		let encoded = ASN1.sequence([ASN1.octetString(Data(repeating: 7, count: 40))])
		XCTAssertNil(ASN1.parse(encoded.dropLast(5)))
	}

	// MARK: - Request

	func testRequestIsASequenceWithOneRequestedCertificate() throws {
		let certID = OCSPCertID(
			issuerNameDER: Data("issuer-name".utf8),
			issuerKeyBytes: Data("issuer-key".utf8),
			serialNumber: serial
		)

		let parsed = try XCTUnwrap(ASN1.parse(OCSPRequestBuilder.build(certID)))
		let tbs = try XCTUnwrap(parsed.children.first)
		let list = try XCTUnwrap(tbs.children.first)
		let request = try XCTUnwrap(list.children.first)
		let id = try XCTUnwrap(request.children.first)

		XCTAssertEqual(id.children.count, 4) // algorithm, name hash, key hash, serial

		let serialElement = try XCTUnwrap(id.children.last)
		XCTAssertEqual(serialElement.tag, ASN1.tagInteger)
		XCTAssertEqual(Array(serialElement.content), Array(serial))

		// The hashes in the request are SHA-1 over what the responder will hash.
		let nameHash = try XCTUnwrap(id.children[1].content as Data?)
		XCTAssertEqual(nameHash.count, 20)
		XCTAssertEqual(Array(id.children[2].content), Array(certID.issuerKeyHashSHA1))
	}

	// MARK: - Response fixtures

	private func fixture(
		status: OCSPStatus,
		serial: Data? = nil,
		thisUpdate: Date = Date(timeIntervalSince1970: 1_800_000_000),
		nextUpdate: Date? = Date(timeIntervalSince1970: 1_800_086_400),
		responseStatus: Int = 0
	) -> Data {
		let serial = serial ?? self.serial

		let certID = ASN1.sequence([
			ASN1.sequence([ASN1.oid(ASN1.OID.sha1), ASN1.null()]),
			ASN1.octetString(Data(repeating: 0x11, count: 20)),
			ASN1.octetString(Data(repeating: 0x22, count: 20)),
			ASN1.integer(magnitude: serial)
		])

		let certStatus: Data
		switch status {
		case .good:
			certStatus = ASN1.implicit(0)
		case .unknown:
			certStatus = ASN1.implicit(2)
		case .revoked(let date, let reason):
			var info: [Data] = []
			if let date { info.append(ASN1.generalizedTime(date)) }
			if let reason { info.append(ASN1.explicit(0, ASN1.tlv(ASN1.tagEnumerated, Data([UInt8(reason)])))) }
			certStatus = ASN1.tlv(0xA1, info.reduce(into: Data()) { $0.append($1) })
		}

		var single: [Data] = [certID, certStatus, ASN1.generalizedTime(thisUpdate)]
		if let nextUpdate {
			single.append(ASN1.explicit(0, ASN1.generalizedTime(nextUpdate)))
		}

		let responseData = ASN1.sequence([
			ASN1.generalizedTime(thisUpdate),
			ASN1.sequence([ASN1.sequence(single)])
		])

		let basic = ASN1.sequence([
			responseData,
			ASN1.sequence([ASN1.oid(ASN1.OID.sha256WithRSA), ASN1.null()]),
			ASN1.bitString(Data(repeating: 0x99, count: 64))
		])

		let wrapper = ASN1.sequence([ASN1.oid(ASN1.OID.ocspBasic), ASN1.octetString(basic)])
		return ASN1.sequence([
			ASN1.tlv(ASN1.tagEnumerated, Data([UInt8(responseStatus)])),
			ASN1.explicit(0, wrapper)
		])
	}

	// MARK: - Response parsing

	func testGoodResponseParses() throws {
		let parsed = try XCTUnwrap(OCSPResponseParser.parse(fixture(status: .good)))

		XCTAssertTrue(parsed.isBasic)
		XCTAssertEqual(parsed.entries.count, 1)
		XCTAssertEqual(parsed.entries[0].status, .good)
		XCTAssertNotNil(parsed.entries[0].thisUpdate)
		XCTAssertNotNil(parsed.entries[0].nextUpdate)
		XCTAssertEqual(Array(try XCTUnwrap(parsed.entry(for: serial)).serialNumber), Array(serial))
	}

	func testRevokedResponseCarriesTheTimeAndReason() throws {
		let revokedAt = Date(timeIntervalSince1970: 1_700_000_000)
		let parsed = try XCTUnwrap(
			OCSPResponseParser.parse(fixture(status: .revoked(date: revokedAt, reason: 4)))
		)

		guard case .revoked(let date, let reason) = parsed.entries[0].status else {
			return XCTFail("expected a revoked status, got \(parsed.entries[0].status)")
		}
		XCTAssertEqual(try XCTUnwrap(date).timeIntervalSince1970, revokedAt.timeIntervalSince1970, accuracy: 1)
		XCTAssertEqual(reason, 4)
	}

	func testUnknownResponseParses() throws {
		let parsed = try XCTUnwrap(OCSPResponseParser.parse(fixture(status: .unknown)))
		XCTAssertEqual(parsed.entries[0].status, .unknown)
	}

	func testSignatureAndSignedBytesAreKeptForTheVerifier() throws {
		let parsed = try XCTUnwrap(OCSPResponseParser.parse(fixture(status: .good)))

		XCTAssertEqual(parsed.signature?.count, 64)
		XCTAssertEqual(parsed.signatureAlgorithmOID, ASN1.OID.sha256WithRSA)
		XCTAssertNotNil(parsed.signedBytes)
		// The bytes the signature covers are a well-formed element of their own.
		XCTAssertNotNil(ASN1.parse(try XCTUnwrap(parsed.signedBytes)))
	}

	func testUnsuccessfulResponseStatusIsReportedNotGuessed() throws {
		let parsed = try XCTUnwrap(OCSPResponseParser.parse(fixture(status: .good, responseStatus: 3)))

		XCTAssertEqual(parsed.responseStatus, 3)
		XCTAssertFalse(parsed.isBasic)
		XCTAssertTrue(parsed.entries.isEmpty)
	}

	func testGarbageIsNotParsedAsGood() {
		XCTAssertNil(OCSPResponseParser.parse(Data("not a response".utf8)))
		XCTAssertNil(OCSPResponseParser.parse(Data()))
	}

	func testEntryLookupIgnoresLeadingZeros() throws {
		let padded = Data([0x00, 0x01, 0x23, 0x45])
		let parsed = try XCTUnwrap(OCSPResponseParser.parse(fixture(status: .good, serial: padded)))

		XCTAssertNotNil(parsed.entry(for: serial))
	}

	// MARK: - Policy

	private func decision(
		_ status: OCSPStatus,
		action: RevocationAction,
		now: Date = Date(timeIntervalSince1970: 1_800_000_000),
		nextUpdate: Date? = Date(timeIntervalSince1970: 1_800_086_400),
		thisUpdate: Date = Date(timeIntervalSince1970: 1_800_000_000)
	) throws -> RevocationDecision {
		let parsed = try XCTUnwrap(OCSPResponseParser.parse(
			fixture(status: status, thisUpdate: thisUpdate, nextUpdate: nextUpdate)
		))
		return try XCTUnwrap(RevocationPolicy.decide(parsed, serial: serial, now: now, action: action))
	}

	func testGoodCertificateIsAllowedAndNotBlocked() throws {
		let verdict = try decision(.good, action: .block)

		XCTAssertFalse(verdict.shouldBlock)
		XCTAssertTrue(verdict.isFresh)
	}

	func testFreshRevocationBlocksUnderTheBlockPolicy() throws {
		let verdict = try decision(.revoked(date: nil, reason: nil), action: .block)

		XCTAssertTrue(verdict.shouldBlock)
		XCTAssertEqual(verdict.summary, "Revoked")
	}

	func testRevocationOnlyWarnsUnderTheWarnPolicy() throws {
		let verdict = try decision(.revoked(date: nil, reason: nil), action: .warn)
		XCTAssertFalse(verdict.shouldBlock)
	}

	func testAStaleAnswerNeverBlocks() throws {
		// nextUpdate is in the past relative to `now`.
		let verdict = try decision(
			.revoked(date: nil, reason: nil),
			action: .block,
			now: Date(timeIntervalSince1970: 1_800_200_000)
		)

		XCTAssertFalse(verdict.isFresh)
		XCTAssertFalse(verdict.shouldBlock)
	}

	func testWithoutNextUpdateAnAnswerIsFreshForADay() throws {
		let fresh = try decision(
			.good,
			action: .allow,
			now: Date(timeIntervalSince1970: 1_800_010_000),
			nextUpdate: nil,
			thisUpdate: Date(timeIntervalSince1970: 1_800_000_000)
		)
		XCTAssertTrue(fresh.isFresh)

		let stale = try decision(
			.good,
			action: .allow,
			now: Date(timeIntervalSince1970: 1_800_200_000),
			nextUpdate: nil,
			thisUpdate: Date(timeIntervalSince1970: 1_800_000_000)
		)
		XCTAssertFalse(stale.isFresh)
	}

	func testAnAnswerAboutAnotherCertificateIsNotUsed() throws {
		let parsed = try XCTUnwrap(OCSPResponseParser.parse(fixture(status: .good, serial: Data([0x09, 0x09]))))
		XCTAssertNil(RevocationPolicy.decide(parsed, serial: serial, now: Date(), action: .block))
	}
}
