//
//  SigningIdentityPolicyTests.swift
//  VexSignTests
//
//  The identity gate that runs before a signing run copies anything.
//
//  The point of these tests is the path that used to have no gate at all: batch, Update All,
//  Shortcuts and self-update never rendered `PreflightChecks`, so an expired or revoked
//  certificate reached zsign there. The pipeline now asks this policy first.
//

import CoreData
import XCTest
@testable import VexSign

final class SigningIdentityPolicyTests: XCTestCase {
	private nonisolated(unsafe) static var storage: Storage?

	override func tearDown() {
		Self.storage = nil
		super.tearDown()
	}

	// MARK: - The certificate half

	@MainActor
	func testAnExpiredCertificateIsRejectedAtItsExpiryInstant() {
		let expiry = Date(timeIntervalSince1970: 1_800_000_000)
		let certificate = _certificate(expiration: expiry)

		// One second before expiry it is still usable; at expiry it is not. The boundary is
		// inclusive on the "expired" side because `notAfter` is the last instant of validity.
		XCTAssertNil(SigningIdentityPolicy.rejection(for: certificate, now: expiry.addingTimeInterval(-1)))
		XCTAssertEqual(
			SigningIdentityPolicy.rejection(for: certificate, now: expiry),
			.certificateExpired(expiresAt: expiry)
		)
	}

	@MainActor
	func testAnUnknownExpiryIsNotTreatedAsExpired() {
		// A certificate whose row has no date is *unknown*, not expired. The produced
		// signature's real validity window is read by the verifier after signing; guessing
		// here would block a perfectly good identity.
		let certificate = _certificate(expiration: nil)
		XCTAssertNil(SigningIdentityPolicy.rejection(for: certificate, now: .distantFuture))
	}

	@MainActor
	func testARevokedCertificateIsRejectedEvenWhenItsDateHasNotPassed() {
		let certificate = _certificate(expiration: Date().addingTimeInterval(86_400), revoked: true)
		XCTAssertEqual(SigningIdentityPolicy.rejection(for: certificate), .certificateRevoked)
	}

	@MainActor
	func testRevocationIsReportedBeforeExpiry() {
		// Both are true; the message must name the one the user can act on. A revoked
		// certificate cannot be fixed by waiting, so it is reported first.
		let certificate = _certificate(expiration: Date(timeIntervalSince1970: 1_000), revoked: true)
		XCTAssertEqual(SigningIdentityPolicy.rejection(for: certificate), .certificateRevoked)
	}

	// MARK: - The request half

	@MainActor
	func testDefaultSigningWithoutACertificateIsRejected() {
		let request = _request(options: Options.defaultOptions, certificate: nil)
		XCTAssertEqual(SigningIdentityPolicy.rejection(for: request), .missingCertificate)
	}

	@MainActor
	func testModifyOnlyNeverNeedsAnIdentity() {
		// `SigningHandler` keeps the row certificate-free for this option, so demanding one
		// would break modify-only signing entirely.
		var options = Options.defaultOptions
		options.signingOption = .onlyModify
		let request = _request(options: options, certificate: nil)
		XCTAssertNil(SigningIdentityPolicy.rejection(for: request))

		// And an attached expired certificate is irrelevant: it is not used.
		let expired = _certificate(expiration: Date(timeIntervalSince1970: 1_000))
		XCTAssertNil(SigningIdentityPolicy.rejection(for: _request(options: options, certificate: expired)))
	}

	@MainActor
	func testDefaultSigningWithAValidCertificatePasses() {
		let certificate = _certificate(expiration: Date().addingTimeInterval(30 * 86_400))
		XCTAssertNil(SigningIdentityPolicy.rejection(for: _request(options: .defaultOptions, certificate: certificate)))
	}

	@MainActor
	func testOverridingPreflightDoesNotExcuseAnInvalidIdentity() {
		// "Sign Anyway" on the preflight sheet covers profile/entitlement compatibility, which
		// can still install. It must not cover an identity that is invalid on its face.
		let expired = _certificate(expiration: Date(timeIntervalSince1970: 1_000))
		let request = SigningRequest(
			app: _signed(),
			options: Options.defaultOptions,
			icon: nil,
			certificate: expired,
			overridesBlockingPreflightIssues: true
		)
		XCTAssertEqual(
			SigningIdentityPolicy.rejection(for: request),
			.certificateExpired(expiresAt: Date(timeIntervalSince1970: 1_000))
		)
	}

	// MARK: - Messages

	@MainActor
	func testRejectionsExplainTheCostAndAreLocalizable() throws {
		let expiry = Date(timeIntervalSince1970: 1_800_000_000)
		for rejection in [
			SigningIdentityPolicy.Rejection.missingCertificate,
			.certificateExpired(expiresAt: expiry),
			.certificateRevoked
		] {
			let message = try XCTUnwrap(rejection.errorDescription)
			XCTAssertFalse(message.isEmpty)
			XCTAssertFalse(SigningIdentityPolicy.logLine(for: rejection).isEmpty)
		}

		let rejection = SigningIdentityPolicy.Rejection.certificateExpired(expiresAt: expiry)
		let expired = rejection.message
		// The message has to say what happens, not only that a date passed.
		XCTAssertTrue(expired.lowercased().contains("install"), expired)
	}

	// MARK: - Pipeline integration

	/// The gate has to be in the pipeline, not only in a helper: a helper nothing calls is
	/// how the old, preflight-only check looked.
	@MainActor
	func testThePipelineAsksTheIdentityPolicyBeforeStarting() throws {
		let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("VexSign/Utilities/Signing/SigningService.swift"))
		let pipeline = try XCTUnwrap(source.range(of: "struct SigningPipeline"))
		let run = String(source[pipeline.lowerBound...])

		let gate = try XCTUnwrap(run.range(of: "SigningIdentityPolicy.rejection(for: request)"))
		let handler = try XCTUnwrap(run.range(of: "SigningHandler(app:"))

		// The refusal must come before the handler is even constructed — and therefore before
		// any copy, modification or zsign invocation.
		XCTAssertLessThan(gate.lowerBound, handler.lowerBound,
						  "the identity gate must run before the signing handler is created")
		XCTAssertTrue(run.contains("return .failure(rejection)"),
					  "a rejected identity must end the run before any work happens")
	}

	@MainActor
	func testEveryNonUIPathReachesTheGateThroughTheAdapter() throws {
		// Batch, AutoSign, Shortcuts and self-update all funnel through `FR.signPackageFile`,
		// which builds a `SigningRequest` for `SigningService`. If that stops being true, the
		// gate is no longer on those paths and this test should fail.
		let sources = ["VexSign/Backend/Observable/BatchJobRunner.swift",
					   "VexSign/Backend/Observable/AutoSignManager.swift",
					   "VexSign/Utilities/FR.swift"]
		for path in sources {
			let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent().deletingLastPathComponent()
				.appendingPathComponent(path))
			XCTAssertTrue(source.contains("FR.signPackageFile(") || source.contains("SigningRequest("), path)
		}
	}

	// MARK: - Pipeline integration, end to end

	/// Drives the **real** `SigningPipeline`, not a fake work item.
	///
	/// The gate is the first thing the pipeline does, so a rejected identity must fail without
	/// a bundle existing at all: the app is not in storage, so any attempt to copy or inspect
	/// it would fail differently. That is what makes this a test of ordering, not just of the
	/// helper the ordering calls.
	@MainActor
	func testTheRealPipelineRefusesAnExpiredIdentityBeforeTouchingTheBundle() async {
		let app = _signed()
		let expired = _certificate(expiration: Date(timeIntervalSince1970: 1_000))

		let result = await SigningPipeline().run(
			SigningRequest(app: app, options: .defaultOptions, icon: nil, certificate: expired)
		) { _ in }

		guard case .failure(let error) = result else {
			return XCTFail("An expired identity must not produce a signed bundle")
		}
		guard case .certificateExpired(let expiresAt)? = error as? SigningIdentityPolicy.Rejection else {
			return XCTFail("Expected certificateExpired, got \(error)")
		}
		XCTAssertEqual(expiresAt, Date(timeIntervalSince1970: 1_000))
	}

	@MainActor
	func testTheRealPipelineRefusesAMissingIdentityForDefaultSigning() async {
		let result = await SigningPipeline().run(
			SigningRequest(app: _signed(), options: .defaultOptions, icon: nil, certificate: nil)
		) { _ in }

		guard case .failure(let error) = result,
			  case .missingCertificate? = error as? SigningIdentityPolicy.Rejection else {
			return XCTFail("Default signing without a certificate must be refused before work starts")
		}
	}

	@MainActor
	func testTheRealPipelineDoesNotGateModifyOnlyOnAnIdentity() async {
		// Modify-only passes the identity gate and fails later for a different reason — the
		// fixture has no bundle on disk. The important part is that it is *not* refused by the
		// identity policy, which would break a certificate-free workflow.
		var options = Options.defaultOptions
		options.signingOption = .onlyModify

		let result = await SigningPipeline().run(
			SigningRequest(app: _signed(), options: options, icon: nil, certificate: nil)
		) { _ in }

		// Whatever the run does next, it must not be the identity gate's refusal.
		switch result {
		case .success:
			break
		case .failure(let error):
			XCTAssertNil(error as? SigningIdentityPolicy.Rejection,
						 "modify-only must not be rejected by the identity gate: \(error)")
		}
	}

	// MARK: - Fixtures

	@MainActor
	private func _signed(_ name: String = "Fixture") -> Signed {
		let storage = Self.storage ?? Storage(inMemory: true)
		Self.storage = storage
		let signed = Signed(context: storage.context)
		signed.name = name
		signed.uuid = UUID().uuidString
		return signed
	}

	@MainActor
	private func _certificate(expiration: Date?, revoked: Bool = false) -> CertificatePair {
		let storage = Self.storage ?? Storage(inMemory: true)
		Self.storage = storage
		let certificate = CertificatePair(context: storage.context)
		certificate.uuid = UUID().uuidString
		certificate.expiration = expiration
		certificate.revoked = revoked
		// Non-optional in the model, so set them instead of relying on defaults.
		certificate.ppQCheck = false
		certificate.isDefault = false
		certificate.date = Date()
		certificate.nickname = "Test Certificate"
		return certificate
	}

	@MainActor
	private func _request(options: Options, certificate: CertificatePair?) -> SigningRequest {
		SigningRequest(app: _signed(), options: options, icon: nil, certificate: certificate)
	}
}
