//
//  SigningIdentityPolicy.swift
//  VexSign
//
//  Whether a signing run may start with the identity it was handed.
//
//  Certificate expiry used to be checked in exactly one place: the preflight sheet the
//  Signing screen shows. Every path that never presents that sheet — batch, Update All,
//  automation/Shortcuts, self-update — went straight to zsign with whatever certificate
//  was attached, so an expired identity produced a bundle that iOS refuses at install,
//  several minutes later, with an error that names the signature rather than the cause.
//
//  The check therefore belongs next to the run, not next to a screen. It is deliberately
//  a pure function over the request so it can be decided before any bytes are copied, and
//  so the reason it refused can be tested without a certificate, a device or zsign.
//
//  Two rules, in this order:
//
//    1. A run that needs an identity must have one.
//    2. That identity must be usable now.
//
//  "Usable" is only reported when it is actually known. A certificate whose expiry could
//  not be read is *not* expired — `SigningIdentity.isExpired` already refuses to guess —
//  and `SignatureVerifier` reads the real X.509 `notAfter` out of the signature this run
//  produces, so a stale or dateless row is still caught after signing.
//
//  The two checks are complementary, not redundant: this one is cheap and stops the run
//  before any work happens, the verifier's is authoritative because it reads the bytes zsign
//  actually wrote. Neither can be excused by "Sign Anyway".
//

import Foundation
import NimbleExtensions

extension SigningIdentityPolicy {

	/// Decides whether `request` may be signed.
	///
	/// - Parameters:
	///   - request: the run about to start.
	///   - now: injected so expiry boundaries are testable without sleeping.
	/// - Returns: the first reason it must not run, or `nil` when it may.
	static func rejection(for request: SigningRequest, now: Date = Date()) -> Rejection? {
		// Modify-only never uses a certificate, and `SigningHandler` deliberately keeps the
		// row certificate-free for that path. Demanding one here would break it.
		guard request.options.signingOption == .default else { return nil }
		guard let certificate = request.certificate else { return .missingCertificate }
		return rejection(for: certificate, now: now)
	}

	/// The identity half of the rule, split out for the picker and for tests.
	static func rejection(for certificate: CertificatePair, now: Date = Date()) -> Rejection? {
		if certificate.revoked { return .certificateRevoked }

		// Unknown expiry is not expired: report only what the row actually holds.
		if let expiration = certificate.expiration, expiration <= now {
			return .certificateExpired(expiresAt: expiration)
		}

		// `notBefore` is not stored on the row, and inventing one would be a guess. The
		// verifier reads the produced signature's real validity window after signing.
		return nil
	}

}
