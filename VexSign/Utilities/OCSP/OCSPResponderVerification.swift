//
//  OCSPResponderVerification.swift
//  VexSign
//
//  This file is the half that makes an answer evidence rather than a claim: the responder's signature.
//
//  The app removed a remote revocation checker because it believed a third party's assertion. Reading
//  an OCSP response and *printing* it would repeat that mistake with more code. What makes this
//  different is that the device can check the responder's signature over the exact bytes in the
//  response, so the answer is either signed by a key we were given or it is not used at all.
//
//  Two layers, on purpose:
//
//    * `OCSPValidator` — which certificate is the responder, in what order they are tried, what a
//      failure is called, and the rule that an unverified answer never produces a decision. Pure,
//      and tested with a fake verifier.
//    * `SecurityOCSPResponderVerifier` — the actual signature check, through `SecKeyVerifySignature`.
//      Five lines of Security.framework, not tested here because it needs a real certificate and a
//      device; the seam is what keeps that honest.
//
//  Still out of scope, and said out loud: chaining the responder certificate to the issuer. A
//  responder signature proves "whoever holds this key signed this", not "Apple's CA vouches for this
//  key". Chain building is `SecTrust` work with a real certificate store, and it is the next step,
//  not something this file pretends to do.
//

import CryptoKit
import Foundation
import Security

// MARK: - Signature check

enum OCSPSignatureOutcome: Equatable, Sendable {
	case valid
	case invalid
	/// The response is signed with something this build cannot check.
	case unsupportedAlgorithm(String)
	/// The certificate could not be turned into a key.
	case unusableCertificate
}

protocol OCSPResponderVerifying: Sendable {
	func verify(message: Data, signature: Data, algorithmOID: [UInt8], certificateDER: Data) -> OCSPSignatureOutcome
}

/// The production check. `SecKeyVerifySignature` wants the *whole* message for the `…Message…`
/// algorithms, which is exactly what `signedBytes` holds.
struct SecurityOCSPResponderVerifier: OCSPResponderVerifying {
	func verify(message: Data, signature: Data, algorithmOID: [UInt8], certificateDER: Data) -> OCSPSignatureOutcome {
		guard let algorithm = Self.algorithm(for: algorithmOID) else {
			return .unsupportedAlgorithm(Self.name(for: algorithmOID))
		}

		guard
			let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
			let key = SecCertificateCopyKey(certificate)
		else {
			return .unusableCertificate
		}

		let verified = SecKeyVerifySignature(key, algorithm, message as CFData, signature as CFData, nil)
		return verified ? .valid : .invalid
	}

	/// An if-chain rather than a `switch` over `[UInt8]` patterns: comparing arrays explicitly is one
	/// fewer thing that has to compile the first time on a machine nobody can test this on.
	static func algorithm(for oid: [UInt8]) -> SecKeyAlgorithm? {
		if oid == ASN1.OID.sha256WithRSA { return .rsaSignatureMessagePKCS1v15SHA256 }
		if oid == ASN1.OID.sha1WithRSA { return .rsaSignatureMessagePKCS1v15SHA1 }
		if oid == ASN1.OID.ecdsaWithSHA256 { return .ecdsaSignatureMessageX962SHA256 }
		if oid == ASN1.OID.ecdsaWithSHA384 { return .ecdsaSignatureMessageX962SHA384 }
		return nil
	}

	/// A dotted name would be nicer, but an OID body is what the parser hands over, and printing it
	/// verbatim beats printing nothing in a log line about an unsupported responder.
	static func name(for oid: [UInt8]) -> String {
		oid.map { String(format: "%02x", $0) }.joined()
	}
}

// MARK: - Which certificate is the responder

enum OCSPCertificateKey {
	/// SHA-1 over the certificate's `subjectPublicKey` bits — the value `ResponderID.byKey` carries.
	static func keyHash(_ certificateDER: Data) -> Data? {
		publicKeyBits(certificateDER).map { Data(Insecure.SHA1.hash(data: $0)) }
	}

	/// Certificate → tbsCertificate → SubjectPublicKeyInfo → BIT STRING, minus the unused-bits byte.
	static func publicKeyBits(_ certificateDER: Data) -> Data? {
		guard
			let certificate = ASN1.parse(certificateDER),
			let tbs = certificate.children.first
		else {
			return nil
		}

		let spki = tbs.children.first { element in
			guard element.tag == ASN1.tagSequence, element.children.count == 2 else { return false }
			return element.children[0].tag == ASN1.tagSequence && element.children[1].tag == ASN1.tagBitString
		}

		guard let bits = spki?.children[1] else { return nil }
		return Data(bits.content.dropFirst())
	}
}

// MARK: - Validation

enum OCSPValidationFailure: Equatable, Sendable {
	case unsuccessfulStatus(Int)
	case noEntryForCertificate
	case missingSignature
	case unsupportedAlgorithm(String)
	case noResponderCertificate
	case signatureInvalid
}

struct OCSPValidation: Equatable, Sendable {
	var decision: RevocationDecision?
	var failure: OCSPValidationFailure?
	/// True when the certificate whose key was used is the one the response named by key.
	var responderKeyMatched: Bool

	var isVerified: Bool { failure == nil && decision != nil }

	static func rejected(_ failure: OCSPValidationFailure, keyMatched: Bool = false) -> OCSPValidation {
		OCSPValidation(decision: nil, failure: failure, responderKeyMatched: keyMatched)
	}
}

enum OCSPValidator {
	/// Verifies the response and, only if it verifies, turns it into a decision.
	///
	/// The order of the checks is the security property: nothing produces a `decision` until a
	/// responder certificate has signed the bytes. A revoked status from an unverified response is
	/// discarded — an attacker who can rewrite a response can write "revoked" just as easily as
	/// "good", and either way it must not change what the device does.
	static func validate(
		_ response: OCSPParsedResponse,
		serial: Data,
		now: Date,
		action: RevocationAction,
		verifier: OCSPResponderVerifying = SecurityOCSPResponderVerifier()
	) -> OCSPValidation {
		guard response.responseStatus == OCSPResponseParser.responseStatusSuccess else {
			return .rejected(.unsuccessfulStatus(response.responseStatus))
		}

		guard response.entry(for: serial) != nil else {
			return .rejected(.noEntryForCertificate)
		}

		guard
			let message = response.signedBytes,
			let signature = response.signature,
			let algorithmOID = response.signatureAlgorithmOID
		else {
			return .rejected(.missingSignature)
		}

		guard !response.responderCertificates.isEmpty else {
			return .rejected(.noResponderCertificate)
		}

		let candidates = orderedCandidates(response)
		var unsupported: String?
		var keyMatched = false

		for candidate in candidates {
			let matchesKey = response.responderID.map { id in
				guard case .byKey(let hash) = id else { return false }
				return OCSPCertificateKey.keyHash(candidate) == hash
			} ?? false

			switch verifier.verify(
				message: message,
				signature: signature,
				algorithmOID: algorithmOID,
				certificateDER: candidate
			) {
			case .valid:
				keyMatched = matchesKey
				guard let decision = RevocationPolicy.decide(response, serial: serial, now: now, action: action) else {
					return .rejected(.noEntryForCertificate, keyMatched: keyMatched)
				}
				return OCSPValidation(decision: decision, failure: nil, responderKeyMatched: keyMatched)

			case .unsupportedAlgorithm(let name):
				unsupported = name

			case .invalid, .unusableCertificate:
				continue
			}
		}

		if let unsupported {
			return .rejected(.unsupportedAlgorithm(unsupported))
		}
		return .rejected(.signatureInvalid)
	}

	/// The certificate the response names by key comes first; the rest are tried in the order the
	/// responder listed them, because a response may embed its certificate anywhere in `certs`.
	static func orderedCandidates(_ response: OCSPParsedResponse) -> [Data] {
		guard case .byKey(let hash)? = response.responderID else {
			return response.responderCertificates
		}

		return response.responderCertificates.sorted { lhs, rhs in
			OCSPCertificateKey.keyHash(lhs) == hash && OCSPCertificateKey.keyHash(rhs) != hash
		}
	}
}
