//
//  OCSP.swift
//  VexSign
//
//  build the request, read the answer, decide what it means.
//
//  Everything in this file is pure: bytes in, bytes out, no network. That is deliberate — a
//  revocation check that cannot be tested against a fixed response is a check nobody can trust, and
//  a parser that only ever sees Apple's live answer will break the first time Apple changes a field.
//
//  What is here is the evidence threw away with the remote checker: the CertID (so the answer
//  is about *this* certificate), the status, the times, and the responder's signature as raw bytes.
//  What is not here — yet — is verifying that signature against the issuer chain; that needs
//  Security.framework and a device, and `OCSPParsedResponse` carries exactly the pieces it needs so
//  it can be added without touching the parser.
//

import Foundation
import CryptoKit
import NimbleExtensions

// MARK: - CertID

/// What a responder is asked about: a certificate, identified by its issuer and serial number.
struct OCSPCertID: Equatable, Sendable {
	/// DER of the issuer's Name (`issuer.rawName`).
	var issuerNameDER: Data
	/// DER of the issuer's public key, or just the key bytes — either is hashed the same way here.
	var issuerKeyBytes: Data
	/// Certificate serial number as big-endian magnitude bytes.
	var serialNumber: Data

	var issuerNameHashSHA1: Data { Data(Insecure.SHA1.hash(data: issuerNameDER)) }
	var issuerKeyHashSHA1: Data { Data(Insecure.SHA1.hash(data: issuerKeyBytes)) }
}

// MARK: - Request

enum OCSPRequestBuilder {
	/// `OCSPRequest ::= SEQUENCE { tbsRequest TBSRequest }` with one CertID, SHA-1, no nonce.
	///
	/// No nonce on purpose: Apple's responder ignores it, and a nonce that is silently dropped looks
	/// like replay protection in the code and is not.
	static func build(_ certID: OCSPCertID) -> Data {
		let algorithm = ASN1.sequence([ASN1.oid(ASN1.OID.sha1), ASN1.null()])

		let request = ASN1.sequence([
			ASN1.sequence([
				algorithm,
				ASN1.octetString(certID.issuerNameHashSHA1),
				ASN1.octetString(certID.issuerKeyHashSHA1),
				ASN1.integer(magnitude: certID.serialNumber)
			])
		])

		// TBSRequest ::= SEQUENCE { requestList SEQUENCE OF Request }
		let tbsRequest = ASN1.sequence([ASN1.sequence([request])])
		return ASN1.sequence([tbsRequest])
	}
}

// MARK: - Response

enum OCSPStatus: Equatable, Sendable {
	case good
	case revoked(date: Date?, reason: Int?)
	case unknown
}

struct OCSPSingleResponse: Equatable, Sendable {
	var serialNumber: Data
	var status: OCSPStatus
	var thisUpdate: Date?
	var nextUpdate: Date?
}

struct OCSPParsedResponse: Equatable, Sendable {
	/// `responseStatus` from the outer OCSPResponse; 0 is successful.
	var responseStatus: Int
	/// Parsed `BasicOCSPResponse`, when there is one.
	var isBasic: Bool
	var producedAt: Date?
	var entries: [OCSPSingleResponse]
	/// The bytes the responder signed (`tbsResponseData`), verbatim.
	var signedBytes: Data?
	/// `signatureAlgorithm` OID body.
	var signatureAlgorithmOID: [UInt8]?
	/// The signature itself, with the BIT STRING padding byte removed.
	var signature: Data?
	/// `ResponderID ::= CHOICE { byName [1] Name, byKey [2] KeyHash }`, as the raw choice:
	/// `.byName(DER of the Name)` or `.byKey(SHA-1 of the responder's public key)`.
	var responderID: OCSPResponderID?
	/// DER of every certificate in the response's `certs` field, in order.
	var responderCertificates: [Data] = []

	/// The entry for a serial, compared as magnitudes (leading zeros ignored).
	func entry(for serial: Data) -> OCSPSingleResponse? {
		let wanted = serial.drop(while: { $0 == 0 })
		return entries.first { $0.serialNumber.drop(while: { $0 == 0 }).elementsEqual(wanted) }
	}
}

enum OCSPResponderID: Equatable, Sendable {
	/// The responder's name, as DER (`[1] EXPLICIT Name`).
	case byName(Data)
	/// SHA-1 over the responder certificate's `subjectPublicKey` bits (`[2] EXPLICIT KeyHash`).
	case byKey(Data)
}

enum OCSPResponseParser {
	static let responseStatusSuccess = 0

	/// Parses an `OCSPResponse` as returned by a responder over `application/ocsp-response`.
	static func parse(_ data: Data) -> OCSPParsedResponse? {
		guard
			let root = ASN1.parse(data),
			root.tag == ASN1.tagSequence,
			let statusElement = root.child(tag: ASN1.tagEnumerated)
		else {
			return nil
		}

		let status = statusElement.content.reduce(0) { ($0 << 8) | Int($1) }
		guard status == responseStatusSuccess else {
			return OCSPParsedResponse(
				responseStatus: status,
				isBasic: false,
				producedAt: nil,
				entries: [],
				signedBytes: nil,
				signatureAlgorithmOID: nil,
				signature: nil
			)
		}

		guard
			let responseBytes = root.child(context: 0),
			let wrapper = responseBytes.children.first,
			let typeElement = wrapper.child(tag: ASN1.tagOID),
			Array(typeElement.content) == ASN1.OID.ocspBasic,
			let octets = wrapper.child(tag: ASN1.tagOctetString),
			let basic = parseBasic(octets.content)
		else {
			return nil
		}

		return basic
	}

	private static func parseBasic(_ data: Data) -> OCSPParsedResponse? {
		guard
			let root = ASN1.parse(data),
			let tbs = root.children.first
		else {
			return nil
		}

		// BasicOCSPResponse ::= SEQUENCE { tbsResponseData, signatureAlgorithm, signature, certs [0] }
		let algorithm = root.children.dropFirst().first { $0.tag == ASN1.tagSequence }
		let signatureBits = root.children.first { $0.tag == ASN1.tagBitString }

		return OCSPParsedResponse(
			responseStatus: responseStatusSuccess,
			isBasic: true,
			producedAt: parseProducedAt(tbs),
			entries: parseSingleResponses(tbs),
			signedBytes: ASN1.tlv(tbs.tag, tbs.content),
			signatureAlgorithmOID: algorithm?.child(tag: ASN1.tagOID).map { Array($0.content) },
			signature: signatureBits.map { Data($0.content.dropFirst()) },
			responderID: parseResponderID(tbs),
			responderCertificates: parseCertificates(root)
		)
	}

	/// ResponseData's second element is the responder's identity, by name or by key hash.
	private static func parseResponderID(_ tbs: ASN1.Element) -> OCSPResponderID? {
		guard
			let element = tbs.children.first(where: { $0.contextNumber == 1 || $0.contextNumber == 2 }),
			let inner = element.children.first
		else {
			return nil
		}

		switch element.contextNumber {
		case 1:
			return .byName(ASN1.tlv(inner.tag, inner.content))
		case 2:
			return .byKey(inner.content)
		default:
			return nil
		}
	}

	/// `certs [0] EXPLICIT SEQUENCE OF Certificate` — re-encoded per certificate so each one can be
	/// handed to Security.framework as DER.
	private static func parseCertificates(_ basicRoot: ASN1.Element) -> [Data] {
		guard
			let wrapper = basicRoot.children.first(where: { $0.contextNumber == 0 }),
			let list = wrapper.children.first
		else {
			return []
		}

		return list.children
			.filter { $0.tag == ASN1.tagSequence }
			.map { ASN1.tlv($0.tag, $0.content) }
	}

	/// `producedAt` is the first GeneralizedTime in ResponseData once the optional version and the
	/// responder identifier are out of the way.
	private static func parseProducedAt(_ tbs: ASN1.Element) -> Date? {
		guard let element = tbs.children.first(where: { $0.tag == ASN1.tagGeneralizedTime }) else {
			return nil
		}
		return ASN1.parseGeneralizedTime(element)
	}

	private static func parseSingleResponses(_ tbs: ASN1.Element) -> [OCSPSingleResponse] {
		// ResponseData ::= SEQUENCE { version [0] OPTIONAL, responderID, producedAt, responses SEQUENCE OF SingleResponse }
		guard
			let responses = tbs.children.last(where: { element in
				element.tag == ASN1.tagSequence && ASN1.parseAll(element.content)?.contains { $0.tag == ASN1.tagSequence } == true
			}),
			let singles = ASN1.parseAll(responses.content)
		else {
			return []
		}

		return singles.compactMap(parseSingle)
	}

	private static func parseSingle(_ single: ASN1.Element) -> OCSPSingleResponse? {
		// SingleResponse ::= SEQUENCE { certID, certStatus, thisUpdate, nextUpdate [0], extensions [1] }
		let children = single.children

		guard
			let certIDIndex = children.firstIndex(where: { $0.tag == ASN1.tagSequence }),
			let serialElement = children[certIDIndex].children.last,
			serialElement.tag == ASN1.tagInteger,
			let statusElement = children.dropFirst(certIDIndex + 1).first(where: { $0.contextNumber != nil })
		else {
			return nil
		}

		let thisUpdate = children.dropFirst(certIDIndex + 1)
			.first(where: { $0.tag == ASN1.tagGeneralizedTime })
			.flatMap(ASN1.parseGeneralizedTime(_:))

		// nextUpdate is [0] EXPLICIT GeneralizedTime; the implicit status tag cannot collide because
		// it was already consumed above.
		let nextUpdate = children
			.first(where: { $0.tag == 0xA0 })
			.flatMap { $0.children.first }
			.flatMap(ASN1.parseGeneralizedTime(_:))

		return OCSPSingleResponse(
			serialNumber: serialElement.content,
			status: status(from: statusElement),
			thisUpdate: thisUpdate,
			nextUpdate: nextUpdate
		)
	}

	private static func status(from element: ASN1.Element) -> OCSPStatus {
		switch element.contextNumber {
		case 0:
			// good [0] IMPLICIT NULL — primitive, empty content.
			return .good
		case 1:
			// revoked [1] IMPLICIT RevokedInfo ::= SEQUENCE { revocationTime, revocationReason [0] OPTIONAL }
			guard element.isConstructed, let info = ASN1.parseAll(element.content) else {
				return .revoked(date: nil, reason: nil)
			}
			let time = info.first(where: { $0.tag == ASN1.tagGeneralizedTime }).flatMap(ASN1.parseGeneralizedTime(_:))
			let reason: Int? = {
				guard
					let wrapped = info.first(where: { $0.contextNumber == 0 }),
					let inner = wrapped.children.first
				else {
					return nil
				}
				return inner.content.reduce(0) { ($0 << 8) | Int($1) }
			}()
			return .revoked(date: time, reason: reason)
		default:
			// unknown [2] IMPLICIT UnknownInfo, and anything this parser does not recognise.
			return .unknown
		}
	}
}

// MARK: - What the app does with an answer

enum RevocationAction: String, CaseIterable, Sendable {
	case allow
	case warn
	case block
}

struct RevocationDecision: Equatable, Sendable {
	var status: OCSPStatus
	var isFresh: Bool
	var action: RevocationAction

	/// Blocking needs both a revocation *and* a fresh answer. A stale "revoked" is a reason to warn,
	/// not to destroy the user's install: the responder may simply be down.
	var shouldBlock: Bool {
		guard case .revoked = status else { return false }
		return action == .block && isFresh
	}

	var summary: String {
		switch status {
		case .good:
			return .localized("Not revoked")
		case .revoked(let date, _):
			return date.map { String.localized("Revoked on %@", arguments: DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)) }
				?? .localized("Revoked")
		case .unknown:
			return .localized("The responder does not know this certificate")
		}
	}
}

enum RevocationPolicy {
	/// Turns a parsed answer into a decision. Pure, so the policy is testable without a responder.
	static func decide(
		_ response: OCSPParsedResponse,
		serial: Data,
		now: Date,
		action: RevocationAction
	) -> RevocationDecision? {
		guard response.responseStatus == OCSPResponseParser.responseStatusSuccess,
			  let entry = response.entry(for: serial)
		else {
			return nil
		}

		let fresh: Bool = {
			guard let nextUpdate = entry.nextUpdate else {
				// No nextUpdate: accept for a day from thisUpdate rather than forever.
				guard let thisUpdate = entry.thisUpdate else { return false }
				return now.timeIntervalSince(thisUpdate) < 86_400
			}
			return now <= nextUpdate
		}()

		return RevocationDecision(status: entry.status, isFresh: fresh, action: action)
	}
}
