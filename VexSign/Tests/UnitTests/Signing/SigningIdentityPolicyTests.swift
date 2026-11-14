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
        let certificate = _certificate(expiration: expiry.addingTimeInterval(86_400))
        let snapshot = CertificateRevocationSnapshot(status: .signed, detail: "", checkedAt: expiry,
            certificateExpires: expiry)

		// One second before expiry it is still usable; at expiry it is not. The boundary is
		// inclusive on the "expired" side because `notAfter` is the last instant of validity.
		XCTAssertNil(SigningIdentityPolicy.rejection(for: certificate, storedSnapshot: snapshot, now: expiry.addingTimeInterval(-1)))
		XCTAssertEqual(
			SigningIdentityPolicy.rejection(for: certificate, storedSnapshot: snapshot, now: expiry),
			.certificateExpired(expiresAt: expiry)
		)
	}

	@MainActor
	func testAnUnknownExpiryIsNotTreatedAsExpired() {
        // Missing cached dates are not expiry evidence. The coordinator and
        // execution gate still require readable current X.509 validity.
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
        // No override excuses revocation, expiry, team/device incompatibility,
        // identity authenticity or required capabilities.
        let revoked = _certificate(expiration: .distantFuture, revoked: true)
		let request = SigningRequest(
			app: _signed(),
			options: Options.defaultOptions,
			icon: nil,
			certificate: revoked,
			overridesBlockingPreflightIssues: true
		)
		XCTAssertEqual(
			SigningIdentityPolicy.rejection(for: request),
			.certificateRevoked
		)
	}

    @MainActor
    func testExpiredPrimaryProfileMetadataDoesNotInvalidateTheActualCertificate() {
        let certificate = _certificate(expiration: Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(SigningIdentityPolicy.rejection(for: certificate, storedSnapshot: nil))
        let snapshot = CertificateRevocationSnapshot(status: .signed, detail: "", checkedAt: Date(),
            certificateExpires: .distantFuture)
        XCTAssertNil(SigningIdentityPolicy.rejection(for: certificate, storedSnapshot: snapshot))
        // The resolver, not this row date, must require a different current
        // compatible profile. Expired profiles themselves still never resolve.
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
		let source = try RepositorySourceFixture.read("VexSign/App/iOS/Infrastructure/Signing/Execution/SigningPipeline.swift")
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
		// Batch, AutoSign, Shortcuts and self-update all funnel through `PackageSigningCoordinator.signPackage`,
		// which builds a `SigningRequest` for `SigningService`. If that stops being true, the
		// gate is no longer on those paths and this test should fail.
		let sources = ["VexSign/App/iOS/Infrastructure/Tasks/BatchJobRunner.swift",
					   "VexSign/App/iOS/Infrastructure/Signing/Execution/AutoSignManager.swift",
					   "VexSign/App/iOS/Infrastructure/Signing/Execution/PackageSigningCoordinator.swift"]
		for path in sources {
			let source = try RepositorySourceFixture.read(path)
			XCTAssertTrue(source.contains("PackageSigningCoordinator.signPackage(") || source.contains("SigningRequest("), path)
		}
	}

	// MARK: - Pipeline integration, end to end

    /// The cheap gate uses certificate-status evidence, never the profile date.
	@MainActor
	func testExpiredIdentityIsRefusedAndReportsItsOwnExpiry() {
        let expired = _certificate(expiration: .distantFuture)
        let snapshot = CertificateRevocationSnapshot(status: .signed, detail: "", checkedAt: Date(),
            certificateExpires: Date(timeIntervalSince1970: 1_000))

        guard case .certificateExpired(let expiresAt)? = SigningIdentityPolicy.rejection(for: expired, storedSnapshot: snapshot) else {
			return XCTFail("An expired identity must not be accepted")
		}
		XCTAssertEqual(expiresAt, Date(timeIntervalSince1970: 1_000))
	}

    /// Missing identity is refused before constructing the worker or copying.
	@MainActor
	func testDefaultSigningWithNoCertificateIsRefused() {
		let request = SigningRequest(app: _signed(), options: .defaultOptions, icon: nil, certificate: nil)
		guard case .missingCertificate? = SigningIdentityPolicy.rejection(for: request) else {
			return XCTFail("Default signing without a certificate must be refused before work starts")
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
