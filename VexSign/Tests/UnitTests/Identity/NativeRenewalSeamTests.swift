//
//  NativeRenewalSeamTests.swift
//  VexSignTests
//
//  Pins the difference between two things the codebase used to treat as one:
//
//    * `SigningMethodCapabilities.nativeAppleAccountSigning` — whether this build signs an
//      in-process CMS signature against an Apple account. Held `.notIntegrated` by a
//      device-evidence gate in `check-native-handoff.py`.
//    * Renewability — whether fresh signing material can be obtained here. An imported
//      `.p12` pair can always be renewed; a free-account profile needs a signed-in session.
//
//  Conflating them made every free-account certificate report `Cannot renew here`, which
//  was wrong and was the most alarming status the screen could show. This test fails if the
//  conflation returns.
//

import XCTest
@testable import VexSign

final class NativeRenewalSeamTests: XCTestCase {
	private let now = Date(timeIntervalSince1970: 1_800_000_000)
	private func days(_ count: Double) -> TimeInterval { count * 86_400 }

	private func record(
		id: String = "cert-1",
		expiration: Date?,
		revoked: Bool = false
	) -> CertificateRecord {
		CertificateRecord(
			id: id,
			uuid: nil,
			nickname: "Free team",
			date: nil,
			expiration: expiration,
			isDefault: false,
			ppQCheck: true,
			revoked: revoked,
			profile: nil,
			additionalProfilePatterns: []
		)
	}

	// MARK: - Imported pairs are always renewable

	func testImportedPairRenewabilityIsNotTiedToTheNativeSigningFlag() {
		// The regression: `Renewability.importedPair` must be a plain fact, so it stays true
		// whatever the native account capability reports.
		XCTAssertTrue(Renewability.importedPair)
	}

	@MainActor
	func testImportedCertificateInsideItsWindowIsActionableNotBlocked() {
		let credential = SigningCredential(
			record: record(expiration: now.addingTimeInterval(days(1))),
			canRenewOnDevice: Renewability.importedPair
		)
		let plan = RenewalPlanner.plan(for: credential, now: now)
		XCTAssertNotEqual(plan.status, .blocked)
		XCTAssertTrue(plan.status.isActionable || plan.status == .urgent)
		XCTAssertNotNil(RenewalPlanner.nextAction(from: [plan]))
	}

	@MainActor
	func testRevokedImportedPairIsStillBlocked() {
		// Decoupling must not make a revoked identity look renewable.
		let credential = SigningCredential(
			record: record(expiration: now.addingTimeInterval(days(100)), revoked: true),
			canRenewOnDevice: Renewability.importedPair
		)
		XCTAssertFalse(credential.canRenewOnDevice)
		XCTAssertEqual(RenewalPlanner.plan(for: credential, now: now).status, .blocked)
	}

	func testLapsedImportedPairIsLapsedNotBlocked() {
		let credential = SigningCredential(
			record: record(expiration: now.addingTimeInterval(-days(3))),
			canRenewOnDevice: Renewability.importedPair
		)
		XCTAssertEqual(RenewalPlanner.plan(for: credential, now: now).status, .lapsed)
	}

	// MARK: - A credential with no date is never healthy

	func testUnparsableProfileIsLapsedRatherThanComfortable() {
		let credential = SigningCredential(
			record: record(expiration: nil),
			canRenewOnDevice: Renewability.importedPair
		)
		let plan = RenewalPlanner.plan(for: credential, now: now)
		XCTAssertEqual(plan.status, .lapsed)
		XCTAssertTrue(plan.status.requiresAttention)
	}

	// MARK: - The gate itself must stay closed

	func testNativeAppleAccountSigningRemainsGated() {
		// This is not a test of convenience: `check-native-handoff.py` refuses
		// `.implemented` without committed genuine-Apple-profile evidence and a physical
		// device ladder. Wiring exists, acceptance does not, so the honest claim is
		// `.notIntegrated`. If this ever fails, that evidence must exist first.
		XCTAssertEqual(
			SigningMethodCapabilities.current.nativeAppleAccountSigning,
			.notIntegrated,
			"Promotion needs VexSign/Documentation/DeviceTesting/evidence/native-signing-promotion.json and a device ladder, not a source edit."
		)
	}

	func testRenewalDoesNotClaimTheGatedCapabilityItDoesNotUse() {
		// There must be no path by which renewal status is derived from the gated flag.
		XCTAssertTrue(Renewability.importedPair)
		XCTAssertNotEqual(
			Renewability.importedPair,
			SigningMethodCapabilities.current.nativeAppleAccountSigning == .implemented,
			"Renewability must not be computed from the native CMS signing claim."
		)
	}
}
