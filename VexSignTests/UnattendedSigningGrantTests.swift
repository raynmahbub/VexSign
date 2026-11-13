//
//  UnattendedSigningGrantTests.swift
//  VexSignTests
//
//  The permission for scheduled signing: what it covers, and everything that ends it.
//

import XCTest
@testable import VexSign

final class UnattendedSigningGrantTests: XCTestCase {
	private typealias Grant = UnattendedSigningGrant

	private let now = Date(timeIntervalSince1970: 1_800_000_000)
	private let certificate = "cert-a"

	private func grant(_ lifetime: Grant.Lifetime = .oneWeek, issuedAt: Date? = nil) throws -> Grant {
		try XCTUnwrap(Grant.issue(
			scope: .signAndQueueUpdates, certificateUUID: certificate, lifetime: lifetime, now: issuedAt ?? now
		))
	}

	private func decision(_ grant: Grant?, certificate: String? = "cert-a", at date: Date? = nil) -> Grant.Decision {
		Grant.decision(grant: grant, scope: .signAndQueueUpdates, certificateUUID: certificate, now: date ?? now)
	}

	private func defaults() throws -> UserDefaults {
		let name = "VexSignGrantTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
		addTeardownBlock { defaults.removePersistentDomain(forName: name) }
		return defaults
	}

	// MARK: - Issuing

	func testAGrantNamesItsCertificateAndEndsWithinTheMaximum() throws {
		for lifetime in Grant.Lifetime.allCases {
			let issued = try grant(lifetime)
			XCTAssertEqual(issued.certificateUUID, certificate)
			XCTAssertEqual(issued.expiresAt.timeIntervalSince(issued.issuedAt), lifetime.interval)
			XCTAssertLessThanOrEqual(lifetime.interval, Grant.maximumLifetime)
			XCTAssertNil(issued.revokedAt)
		}
	}

	func testAGrantCannotBeIssuedForNoCertificate() {
		XCTAssertNil(Grant.issue(scope: .signAndQueueUpdates, certificateUUID: "", lifetime: .oneDay, now: now))
		XCTAssertNil(Grant.issue(scope: .signAndQueueUpdates, certificateUUID: "  ", lifetime: .oneDay, now: now))
	}

	// MARK: - Deciding

	func testNoGrantAuthorizesNothing() {
		XCTAssertEqual(decision(nil), .noGrant)
	}

	func testAFreshGrantAuthorizesItsCertificateOnly() throws {
		let issued = try grant()
		XCTAssertEqual(decision(issued), .authorized)
		XCTAssertEqual(decision(issued, certificate: "cert-b"), .differentCertificate)
		XCTAssertEqual(decision(issued, certificate: nil), .differentCertificate)
		XCTAssertEqual(decision(issued, certificate: ""), .differentCertificate)
	}

	func testAGrantStopsAtItsExpiry() throws {
		let issued = try grant(.oneDay)
		XCTAssertEqual(decision(issued, at: issued.expiresAt.addingTimeInterval(-1)), .authorized)
		XCTAssertEqual(decision(issued, at: issued.expiresAt), .expired)
		XCTAssertEqual(decision(issued, at: issued.expiresAt.addingTimeInterval(86_400 * 365)), .expired)
	}

	func testARevokedGrantNeverRevives() throws {
		var issued = try grant()
		issued.revokedAt = now.addingTimeInterval(60)
		XCTAssertEqual(decision(issued, at: now.addingTimeInterval(120)), .revoked)
		// Still revoked, not "expired", once its time would have run out.
		XCTAssertEqual(decision(issued, at: issued.expiresAt.addingTimeInterval(1)), .revoked)
	}

	func testStoredDatesAnIssuedGrantCouldNotHaveAreRejected() throws {
		let template = try grant()
		func tampered(issuedAt: Date, expiresAt: Date) -> Grant {
			Grant(id: template.id, scope: template.scope, certificateUUID: certificate,
			      issuedAt: issuedAt, expiresAt: expiresAt, revokedAt: nil)
		}

		// Longer than the maximum.
		XCTAssertEqual(decision(tampered(issuedAt: now, expiresAt: now.addingTimeInterval(86_400 * 365))), .invalid)
		// Starts in the future.
		XCTAssertEqual(
			decision(tampered(issuedAt: now.addingTimeInterval(86_400), expiresAt: now.addingTimeInterval(2 * 86_400))),
			.invalid
		)
		// Ends before it starts.
		XCTAssertEqual(decision(tampered(issuedAt: now, expiresAt: now.addingTimeInterval(-1))), .invalid)
	}

	func testOnlyAuthorizedIsAuthorized() {
		let all: [Grant.Decision] = [
			.authorized, .noGrant, .revoked, .expired, .invalid, .scopeNotCovered, .differentCertificate
		]
		XCTAssertEqual(all.filter(\.isAuthorized), [.authorized])
		for decision in all { XCTAssertFalse(decision.explanation.isEmpty) }
	}

	// MARK: - Store

	func testTheStoreStartsEmptyAndRoundTrips() throws {
		let defaults = try defaults()
		XCTAssertNil(UnattendedSigningGrantStore.current(defaults: defaults))

		let issued = try grant()
		XCTAssertTrue(UnattendedSigningGrantStore.save(issued, defaults: defaults))
		XCTAssertEqual(UnattendedSigningGrantStore.current(defaults: defaults), issued)
		XCTAssertEqual(
			UnattendedSigningGrantStore.decision(
				scope: .signAndQueueUpdates, certificateUUID: certificate, now: now, defaults: defaults
			),
			.authorized
		)
	}

	func testRevokingEndsTheGrantAndKeepsTheRecord() throws {
		let defaults = try defaults()
		UnattendedSigningGrantStore.save(try grant(), defaults: defaults)

		UnattendedSigningGrantStore.revoke(now: now.addingTimeInterval(10), defaults: defaults)

		XCTAssertEqual(UnattendedSigningGrantStore.current(defaults: defaults)?.revokedAt, now.addingTimeInterval(10))
		XCTAssertEqual(
			UnattendedSigningGrantStore.decision(
				scope: .signAndQueueUpdates, certificateUUID: certificate, now: now.addingTimeInterval(20), defaults: defaults
			),
			.revoked
		)
		// Revoking again does not move the date.
		UnattendedSigningGrantStore.revoke(now: now.addingTimeInterval(99), defaults: defaults)
		XCTAssertEqual(UnattendedSigningGrantStore.current(defaults: defaults)?.revokedAt, now.addingTimeInterval(10))
	}

	func testAnUnreadableStoredGrantAuthorizesNothing() throws {
		let defaults = try defaults()
		defaults.set(Data("{}".utf8), forKey: UnattendedSigningGrantStore.key)
		XCTAssertNil(UnattendedSigningGrantStore.current(defaults: defaults))
		XCTAssertEqual(
			UnattendedSigningGrantStore.decision(scope: .signAndQueueUpdates, certificateUUID: certificate, defaults: defaults),
			.noGrant
		)
	}

	func testTheStoredGrantHoldsNoSecret() throws {
		let data = try JSONEncoder().encode(try grant())
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertEqual(Set(object.keys), ["id", "scope", "certificateUUID", "issuedAt", "expiresAt"])
	}

	// MARK: - The gate

	func testAScheduledPassSignsOnlyWhenAuthorized() {
		let refusals: [Grant.Decision] = [.noGrant, .revoked, .expired, .invalid, .scopeNotCovered, .differentCertificate]
		for decision in refusals {
			XCTAssertEqual(
				BackgroundAutomation.effectivePolicy(preferred: .signAndQueue, fromBackground: true, decision: decision),
				.notifyOnly, "\(decision)"
			)
		}
		XCTAssertEqual(
			BackgroundAutomation.effectivePolicy(preferred: .signAndQueue, fromBackground: true, decision: .authorized),
			.signAndQueue
		)
	}

	func testARunTheUserStartedDoesNotNeedAGrant() {
		XCTAssertEqual(
			BackgroundAutomation.effectivePolicy(preferred: .signAndQueue, fromBackground: false, decision: .noGrant),
			.signAndQueue
		)
	}

	func testAGrantNeverTurnsNotifyOnlyIntoSigning() {
		for fromBackground in [true, false] {
			XCTAssertEqual(
				BackgroundAutomation.effectivePolicy(preferred: .notifyOnly, fromBackground: fromBackground, decision: .authorized),
				.notifyOnly
			)
		}
	}
}
