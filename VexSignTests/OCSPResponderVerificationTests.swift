//
//  OCSPResponderVerificationTests.swift
//  VexSignTests
//
//  the responder's signature, and the rule that matters more than the signature — nothing
//  produces a decision until the bytes are verified.
//
//  `SecurityOCSPResponderVerifier` is the one piece here that cannot run in this target: it needs a
//  real certificate and a device key store. Everything around it — which certificate is tried, in
//  what order, what a failure is called, and whether a decision is produced at all — is pure and is
//  what these tests hold to.
//

import CryptoKit
import Foundation
import XCTest
@testable import VexSign

final class OCSPResponderVerificationTests: XCTestCase {
	private let serial = Data([0x2A, 0x00, 0x01])

	// MARK: - Fixtures

	/// A certificate-shaped blob with a known SubjectPublicKeyInfo, built with the same writer the
	/// request uses. Not a real certificate: enough structure for the walk that finds the key bits.
	private func certificate(publicKey: Data, subject: String) -> Data {
		let algorithm = ASN1.sequence([ASN1.oid(ASN1.OID.sha256WithRSA), ASN1.null()])
		let name = ASN1.sequence([
			ASN1.tlv(0x31, ASN1.sequence([ASN1.oid([0x55, 0x04, 0x03]), ASN1.tlv(0x0C, Data(subject.utf8))]))
		])
		let spki = ASN1.sequence([
			ASN1.sequence([
				ASN1.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
				ASN1.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
			]),
			ASN1.bitString(publicKey)
		])
		let now = Date(timeIntervalSince1970: 1_800_000_000)
		let tbs = ASN1.sequence([
			ASN1.explicit(0, ASN1.integer(2)),
			ASN1.integer(7),
			algorithm,
			name,
			ASN1.sequence([ASN1.generalizedTime(now), ASN1.generalizedTime(now)]),
			name,
			spki
		])
		return ASN1.sequence([tbs, algorithm, ASN1.bitString(Data([0xDE, 0xAD]))])
	}

	private func response(
		status: OCSPStatus = .good,
		responderCertificates: [Data] = [],
		responderKeyHash: Data? = nil,
		includeSignature: Bool = true,
		thisUpdate: Date = Date(timeIntervalSince1970: 1_800_000_000),
		nextUpdate: Date? = Date(timeIntervalSince1970: 1_800_086_400)
	) -> OCSPParsedResponse {
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
		case .revoked:
			certStatus = ASN1.tlv(0xA1, ASN1.generalizedTime(Date(timeIntervalSince1970: 1_700_000_000)))
		}

		var single: [Data] = [certID, certStatus, ASN1.generalizedTime(thisUpdate)]
		if let nextUpdate {
			single.append(ASN1.explicit(0, ASN1.generalizedTime(nextUpdate)))
		}

		// ResponderID.byKey is [2] EXPLICIT OCTET STRING — the OCTET STRING is not optional.
		let responderID = ASN1.explicit(2, ASN1.octetString(responderKeyHash ?? Data(repeating: 0x33, count: 20)))
		let responseData = ASN1.sequence([
			responderID,
			ASN1.generalizedTime(thisUpdate),
			ASN1.sequence([ASN1.sequence(single)])
		])

		var basic: [Data] = [responseData]
		if includeSignature {
			basic.append(ASN1.sequence([ASN1.oid(ASN1.OID.sha256WithRSA), ASN1.null()]))
			basic.append(ASN1.bitString(Data(repeating: 0xAB, count: 64)))
		}
		if !responderCertificates.isEmpty {
			basic.append(ASN1.explicit(0, ASN1.sequence(responderCertificates)))
		}

		let wrapper = ASN1.sequence([ASN1.oid(ASN1.OID.ocspBasic), ASN1.octetString(ASN1.sequence(basic))])
		let outer = ASN1.sequence([ASN1.tlv(ASN1.tagEnumerated, Data([0])), ASN1.explicit(0, wrapper)])

		return OCSPResponseParser.parse(outer)!
	}

	private final class FakeVerifier: OCSPResponderVerifying, @unchecked Sendable {
		var outcome: @Sendable (Data) -> OCSPSignatureOutcome = { _ in .valid }
		private(set) var tried: [Data] = []

		func verify(message: Data, signature: Data, algorithmOID: [UInt8], certificateDER: Data) -> OCSPSignatureOutcome {
			tried.append(certificateDER)
			return outcome(certificateDER)
		}
	}

	// MARK: - Key walk

	func testPublicKeyBitsAreFoundThroughTheSubjectPublicKeyInfo() {
		let key = Data((0..<32).map { UInt8($0) })
		let cert = certificate(publicKey: key, subject: "Responder")

		XCTAssertEqual(OCSPCertificateKey.publicKeyBits(cert), key)
	}

	func testKeyHashIsSHA1OverThePublicKeyBits() {
		let key = Data(repeating: 0x5A, count: 32)
		let cert = certificate(publicKey: key, subject: "Responder")

		let expected = Data(Insecure.SHA1.hash(data: key))
		XCTAssertEqual(OCSPCertificateKey.keyHash(cert), expected)
	}

	func testGarbageHasNoKey() {
		XCTAssertNil(OCSPCertificateKey.keyHash(Data("nope".utf8)))
	}

	// MARK: - Candidate ordering

	func testTheCertificateNamedByKeyIsTriedFirst() {
		let matching = certificate(publicKey: Data(repeating: 1, count: 32), subject: "Responder")
		let other = certificate(publicKey: Data(repeating: 2, count: 32), subject: "Other")
		let hash = OCSPCertificateKey.keyHash(matching)!

		let parsed = response(responderCertificates: [other, matching], responderKeyHash: hash)
		XCTAssertEqual(parsed.responderID, .byKey(hash))
		let ordered = OCSPValidator.orderedCandidates(parsed)

		XCTAssertEqual(ordered.count, 2)
		XCTAssertEqual(ordered.first, matching)
	}

	func testWithoutAKeyIDTheOrderIsUnchanged() {
		let one = certificate(publicKey: Data(repeating: 1, count: 32), subject: "One")
		let two = certificate(publicKey: Data(repeating: 2, count: 32), subject: "Two")

		var parsed = response(responderCertificates: [one, two])
		parsed.responderID = nil

		XCTAssertEqual(OCSPValidator.orderedCandidates(parsed), [one, two])
	}

	// MARK: - Validation

	func testAVerifiedGoodResponseProducesADecision() {
		let cert = certificate(publicKey: Data(repeating: 1, count: 32), subject: "Responder")
		let parsed = response(responderCertificates: [cert], responderKeyHash: OCSPCertificateKey.keyHash(cert))

		let validation = OCSPValidator.validate(parsed, serial: serial, now: Date(timeIntervalSince1970: 1_800_000_000), action: .block, verifier: FakeVerifier())

		XCTAssertNil(validation.failure)
		XCTAssertTrue(validation.isVerified)
		XCTAssertTrue(validation.responderKeyMatched)
		XCTAssertFalse(validation.decision?.shouldBlock ?? true)
	}

	func testAFreshRevocationFromAVerifiedResponderBlocks() {
		let cert = certificate(publicKey: Data(repeating: 1, count: 32), subject: "Responder")
		let parsed = response(
			status: .revoked(date: nil, reason: nil),
			responderCertificates: [cert],
			responderKeyHash: OCSPCertificateKey.keyHash(cert)
		)

		let validation = OCSPValidator.validate(parsed, serial: serial, now: Date(timeIntervalSince1970: 1_800_000_000), action: .block, verifier: FakeVerifier())

		XCTAssertTrue(try XCTUnwrap(validation.decision).shouldBlock)
	}

	/// The point of the whole file: an unverified "revoked" changes nothing.
	func testAnUnverifiedRevocationProducesNoDecision() {
		let cert = certificate(publicKey: Data(repeating: 1, count: 32), subject: "Responder")
		let parsed = response(
			status: .revoked(date: nil, reason: nil),
			responderCertificates: [cert],
			responderKeyHash: OCSPCertificateKey.keyHash(cert)
		)

		let verifier = FakeVerifier()
		verifier.outcome = { _ in .invalid }

		let validation = OCSPValidator.validate(parsed, serial: serial, now: Date(), action: .block, verifier: verifier)

		XCTAssertEqual(validation.failure, .signatureInvalid)
		XCTAssertNil(validation.decision)
		XCTAssertFalse(validation.isVerified)
	}

	func testEveryCandidateIsTried() {
		let one = certificate(publicKey: Data(repeating: 1, count: 32), subject: "One")
		let two = certificate(publicKey: Data(repeating: 2, count: 32), subject: "Two")
		let parsed = response(responderCertificates: [one, two])

		let verifier = FakeVerifier()
		verifier.outcome = { $0 == two ? .valid : .invalid }

		let validation = OCSPValidator.validate(parsed, serial: serial, now: Date(timeIntervalSince1970: 1_800_000_000), action: .allow, verifier: verifier)

		XCTAssertEqual(verifier.tried, [one, two])
		XCTAssertTrue(validation.isVerified)
		XCTAssertFalse(validation.responderKeyMatched) // the response named no matching key
	}

	func testNoEmbeddedCertificateIsRejected() {
		let parsed = response(responderCertificates: [])
		let validation = OCSPValidator.validate(parsed, serial: serial, now: Date(), action: .block, verifier: FakeVerifier())

		XCTAssertEqual(validation.failure, .noResponderCertificate)
		XCTAssertNil(validation.decision)
	}

	func testAnUnsupportedAlgorithmIsNamedRatherThanBlamedOnTheSignature() {
		let cert = certificate(publicKey: Data(repeating: 1, count: 32), subject: "Responder")
		let parsed = response(responderCertificates: [cert])

		let verifier = FakeVerifier()
		verifier.outcome = { _ in .unsupportedAlgorithm("2a8648ce3d040309") }

		let validation = OCSPValidator.validate(parsed, serial: serial, now: Date(), action: .block, verifier: verifier)

		XCTAssertEqual(validation.failure, .unsupportedAlgorithm("2a8648ce3d040309"))
		XCTAssertNil(validation.decision)
	}

	func testAMissingSignatureIsRejectedBeforeAnyCertificateIsTried() {
		let cert = certificate(publicKey: Data(repeating: 1, count: 32), subject: "Responder")
		let parsed = response(responderCertificates: [cert], includeSignature: false)

		let verifier = FakeVerifier()
		let validation = OCSPValidator.validate(parsed, serial: serial, now: Date(), action: .block, verifier: verifier)

		XCTAssertEqual(validation.failure, .missingSignature)
		XCTAssertTrue(verifier.tried.isEmpty)
	}

	func testAnAnswerAboutAnotherCertificateIsRejectedBeforeVerification() {
		let cert = certificate(publicKey: Data(repeating: 1, count: 32), subject: "Responder")
		let parsed = response(responderCertificates: [cert])

		let verifier = FakeVerifier()
		let validation = OCSPValidator.validate(parsed, serial: Data([0x09]), now: Date(), action: .block, verifier: verifier)

		XCTAssertEqual(validation.failure, .noEntryForCertificate)
		XCTAssertTrue(verifier.tried.isEmpty)
	}

	func testAnUnsuccessfulStatusIsRejected() {
		var parsed = response(responderCertificates: [certificate(publicKey: Data([1]), subject: "R")])
		parsed.responseStatus = 6

		XCTAssertEqual(
			OCSPValidator.validate(parsed, serial: serial, now: Date(), action: .block, verifier: FakeVerifier()).failure,
			.unsuccessfulStatus(6)
		)
	}

	// MARK: - Algorithm mapping

	func testTheSignatureAlgorithmsAppleAndECDSARespondersUseAreMapped() {
		XCTAssertNotNil(SecurityOCSPResponderVerifier.algorithm(for: ASN1.OID.sha256WithRSA))
		XCTAssertNotNil(SecurityOCSPResponderVerifier.algorithm(for: ASN1.OID.sha1WithRSA))
		XCTAssertNotNil(SecurityOCSPResponderVerifier.algorithm(for: ASN1.OID.ecdsaWithSHA256))
		XCTAssertNotNil(SecurityOCSPResponderVerifier.algorithm(for: ASN1.OID.ecdsaWithSHA384))
		XCTAssertNil(SecurityOCSPResponderVerifier.algorithm(for: [0xFF, 0x00]))
	}

	func testAnUnsupportedAlgorithmIsReportedWithItsBytes() {
		XCTAssertEqual(SecurityOCSPResponderVerifier.name(for: [0x2A, 0x03]), "2a03")
	}
}
