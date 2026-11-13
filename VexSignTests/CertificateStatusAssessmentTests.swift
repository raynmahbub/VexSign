//
//  CertificateStatusAssessmentTests.swift
//  VexSignTests
//
//  The single certificate status: what may be called valid, and what each kind of
//  missing evidence is called instead.
//

import XCTest
@testable import VexSign

final class CertificateStatusAssessmentTests: XCTestCase {
	private let now = Date(timeIntervalSince1970: 1_800_000_000)
	private var nextYear: Date { now.addingTimeInterval(365 * 86_400) }
	private var lastWeek: Date { now.addingTimeInterval(-7 * 86_400) }

	private func assess(
		certificateExpiry: Date? = nil,
		profileExpiry: Date? = nil,
		revokedOnRecord: Bool = false,
		evidence: CertificateRevocationEvidence
	) -> CertificateStatusAssessment {
		CertificateStatusAssessment.assess(
			.init(
				certificateExpiry: certificateExpiry ?? nextYear,
				profileExpiry: profileExpiry ?? nextYear,
				revokedOnRecord: revokedOnRecord,
				evidence: evidence
			),
			now: now
		)
	}

	// MARK: - Valid needs positive, recent evidence

	func testRecentPositiveEvidenceIsValid() {
		let result = assess(evidence: .good(checkedAt: now.addingTimeInterval(-60)))
		XCTAssertEqual(result, .init(status: .valid, reason: .positiveEvidence))
		XCTAssertFalse(result.status.blocksSigning)
	}

	func testNotHavingExpiredIsNotValid() {
		// The case the status exists for: far from expiry, never checked.
		let result = assess(evidence: .notChecked)
		XCTAssertEqual(result, .init(status: .unknown, reason: .notChecked))
	}

	func testPositiveEvidenceStopsCountingAfterADay() {
		let window = CertificateStatusAssessment.evidenceValidity
		XCTAssertEqual(assess(evidence: .good(checkedAt: now.addingTimeInterval(-window))).status, .valid)
		XCTAssertEqual(
			assess(evidence: .good(checkedAt: now.addingTimeInterval(-window - 1))),
			.init(status: .unknown, reason: .evidenceTooOld)
		)
	}

	func testEvidenceDatedInTheFutureIsNotTrustedIndefinitely() {
		// A clock set back after the check must not keep the answer alive.
		let result = assess(evidence: .good(checkedAt: now.addingTimeInterval(3 * 86_400)))
		XCTAssertEqual(result, .init(status: .unknown, reason: .evidenceTooOld))
	}

	// MARK: - A failed check is neither proof

	func testAnUnreachableResponderIsItsOwnStatus() {
		let result = assess(evidence: .responderUnreachable)
		XCTAssertEqual(result, .init(status: .networkUnavailable, reason: .responderUnreachable))
		XCTAssertFalse(result.status.blocksSigning, "No answer is not a revocation")
	}

	func testAnUnsupportedCheckIsItsOwnStatus() {
		XCTAssertEqual(
			assess(evidence: .unsupported),
			.init(status: .unsupported, reason: .revocationUnsupported)
		)
	}

	func testAnInconclusiveCheckIsUnknown() {
		XCTAssertEqual(assess(evidence: .inconclusive), .init(status: .unknown, reason: .inconclusive))
	}

	func testNoFailureIsEverShownAsValidOrRevoked() {
		for evidence: CertificateRevocationEvidence in [.notChecked, .responderUnreachable, .unsupported, .inconclusive] {
			let status = assess(evidence: evidence).status
			XCTAssertNotEqual(status, .valid)
			XCTAssertNotEqual(status, .revoked)
		}
	}

	// MARK: - Expiry

	func testAnExpiredCertificateIsExpiredEvenWithFreshPositiveEvidence() {
		let result = assess(certificateExpiry: lastWeek, evidence: .good(checkedAt: now))
		XCTAssertEqual(result, .init(status: .expired, reason: .certificateExpired))
		XCTAssertTrue(result.status.blocksSigning)
	}

	func testAnExpiredProfileIsExpired() {
		XCTAssertEqual(
			assess(profileExpiry: lastWeek, evidence: .good(checkedAt: now)),
			.init(status: .expired, reason: .profileExpired)
		)
	}

	func testTheMomentOfExpiryCountsAsExpired() {
		XCTAssertEqual(assess(profileExpiry: now, evidence: .good(checkedAt: now)).status, .expired)
	}

	func testExpiryNeedsNoNetwork() {
		XCTAssertEqual(assess(profileExpiry: lastWeek, evidence: .responderUnreachable).status, .expired)
		XCTAssertEqual(assess(profileExpiry: lastWeek, evidence: .notChecked).status, .expired)
	}

	func testUnknownDatesDoNotInventAnExpiry() {
		let result = CertificateStatusAssessment.assess(
			.init(certificateExpiry: nil, profileExpiry: nil, revokedOnRecord: false, evidence: .good(checkedAt: now)),
			now: now
		)
		XCTAssertEqual(result.status, .valid)
	}

	// MARK: - Revocation

	func testRevocationOutranksEverything() {
		XCTAssertEqual(
			assess(certificateExpiry: lastWeek, profileExpiry: lastWeek, evidence: .revoked),
			.init(status: .revoked, reason: .revokedByIssuer)
		)
	}

	func testARecordedRevocationSurvivesLaterGoodOrMissingEvidence() {
		for evidence: CertificateRevocationEvidence in [.good(checkedAt: now), .notChecked, .responderUnreachable] {
			XCTAssertEqual(
				assess(revokedOnRecord: true, evidence: evidence),
				.init(status: .revoked, reason: .revokedOnRecord)
			)
		}
	}

	// MARK: - Reading a failed trust evaluation

	func testOnlyAnExplicitRevocationCodeIsRevoked() {
		XCTAssertEqual(CertificateRevocationEvidence.classify(trustErrorCode: -67_820), .revoked)
	}

	func testAnIncompleteRevocationCheckIsAnUnreachableResponder() {
		XCTAssertEqual(CertificateRevocationEvidence.classify(trustErrorCode: -67_635), .responderUnreachable)
	}

	func testOtherTrustFailuresSayNothingAboutRevocation() {
		// Expired leaf, untrusted root, generic failure, and a code that means nothing.
		for code in [-67_818, -67_843, -25_318, 0, 12_345] {
			XCTAssertEqual(CertificateRevocationEvidence.classify(trustErrorCode: code), .inconclusive, "\(code)")
		}
	}

	// MARK: - Stored snapshots

	func testASnapshotCarriesTheReasonForAMissingVerdict() {
		let checkedAt = now.addingTimeInterval(-120)
		func evidence(_ status: CertificateStatusValue, _ gap: CertificateRevocationSnapshot.Gap?) -> CertificateRevocationEvidence {
			CertificateRevocationSnapshot(status: status, detail: "", checkedAt: checkedAt, gap: gap).evidence
		}

		XCTAssertEqual(evidence(.signed, nil), .good(checkedAt: checkedAt))
		XCTAssertEqual(evidence(.revoked, nil), .revoked)
		XCTAssertEqual(evidence(.unknown, nil), .inconclusive)
		XCTAssertEqual(evidence(.unknown, .responderUnreachable), .responderUnreachable)
		XCTAssertEqual(evidence(.unknown, .unsupported), .unsupported)
	}

	func testSnapshotsWrittenBeforeTheReasonWasRecordedStillDecode() throws {
		let legacy = Data(#"{"uuid":{"status":"signed","detail":"ok","checkedAt":700000000}}"#.utf8)
		let decoded = try JSONDecoder().decode([String: CertificateRevocationSnapshot].self, from: legacy)
		let snapshot = try XCTUnwrap(decoded["uuid"])

		XCTAssertEqual(snapshot.status, .signed)
		XCTAssertNil(snapshot.gap)
		XCTAssertNil(snapshot.certificateExpires)
	}

	func testTheNewSnapshotFieldsRoundTripAndHoldNoKeyMaterial() throws {
		let snapshot = CertificateRevocationSnapshot(
			status: .unknown,
			detail: "The responder did not answer.",
			checkedAt: now,
			gap: .responderUnreachable,
			certificateExpires: nextYear
		)
		let data = try JSONEncoder().encode(snapshot)

		XCTAssertEqual(try JSONDecoder().decode(CertificateRevocationSnapshot.self, from: data), snapshot)
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertEqual(Set(object.keys), ["status", "detail", "checkedAt", "gap", "certificateExpires"])
	}

	func testEveryStatusHasATitleAndAnIcon() {
		for status in CertificateStatus.allCases {
			XCTAssertFalse(status.title.isEmpty)
			XCTAssertFalse(status.icon.isEmpty)
		}
		XCTAssertEqual(Set(CertificateStatus.allCases.map(\.title)).count, CertificateStatus.allCases.count)
	}

	// MARK: - Signing gate

	func testAnExpiredCertificateDateRefusesTheRun() {
		XCTAssertEqual(
			SigningIdentityPolicy.rejection(certificateExpiry: lastWeek, now: now),
			.certificateExpired(expiresAt: lastWeek)
		)
		XCTAssertEqual(
			SigningIdentityPolicy.rejection(certificateExpiry: now, now: now),
			.certificateExpired(expiresAt: now)
		)
	}

	func testAnUnreadOrFutureCertificateDateDoesNotRefuseTheRun() {
		XCTAssertNil(SigningIdentityPolicy.rejection(certificateExpiry: nil, now: now))
		XCTAssertNil(SigningIdentityPolicy.rejection(certificateExpiry: nextYear, now: now))
	}

	func testTheStoredSnapshotIsReadableByCertificateUUID() throws {
		let name = "VexSignCertificateSnapshots.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
		defer { defaults.removePersistentDomain(forName: name) }

		XCTAssertNil(CertificateRevocationSnapshot.stored(forCertificateUUID: "a", defaults: defaults))

		let snapshot = CertificateRevocationSnapshot(status: .signed, detail: "", checkedAt: now, certificateExpires: lastWeek)
		defaults.set(try JSONEncoder().encode(["a": snapshot]), forKey: CertificateRevocationSnapshot.storageKey)

		XCTAssertEqual(CertificateRevocationSnapshot.stored(forCertificateUUID: "a", defaults: defaults), snapshot)
		XCTAssertNil(CertificateRevocationSnapshot.stored(forCertificateUUID: "b", defaults: defaults))

		defaults.set(Data("not json".utf8), forKey: CertificateRevocationSnapshot.storageKey)
		XCTAssertNil(CertificateRevocationSnapshot.stored(forCertificateUUID: "a", defaults: defaults))
	}
}
