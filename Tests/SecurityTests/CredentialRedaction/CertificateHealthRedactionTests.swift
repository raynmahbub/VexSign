//
//  CertificateHealthRedactionTests.swift
//  VexSignTests
//
//  Covers the shareable redacted certificate health card: it must keep the
//  operational facts reviewers need (OCSP status, expiries, device scope,
//  entitlement names) while never carrying profile payloads, entitlement
//  values, bundle identifiers, team identifiers, or device UDIDs.
//

import XCTest
@testable import VexSign

final class CertificateHealthRedactionTests: XCTestCase {

	private func makeHealth(
		entitlements: String,
		allDevices: Bool = false,
		deviceCount: Int = 3,
		revocation: CertificateHealth.Revocation = .unknown
	) -> CertificateHealth {
		CertificateHealth(
			id: "CERT-UUID-1234",
			name: "Development Certificate",
			teamID: "ABCD123456",
			teamName: "Example Team Ltd",
			expires: Date(timeIntervalSince1970: 1_760_000_000),
			certificateExpires: Date(timeIntervalSince1970: 1_770_000_000),
			deviceCount: deviceCount,
			allDevices: allDevices,
			applicationIdentifier: "TEAMID.com.example.secretapp",
			push: true,
			debugEntitlement: false,
			entitlements: entitlements,
			provision: "<plist><key>ProvisionedDevices</key><array><string>00008030-001A2B3C4D5E6F70</string></array></plist>",
			revocation: revocation,
			checkedAt: Date(timeIntervalSince1970: 1_759_900_000),
			detail: "test detail"
		)
	}

	private let richEntitlements = """
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0">
		<dict>
			<key>application-identifier</key>
			<string>ABCD123456.com.example.secretapp</string>
			<key>com.apple.developer.team-identifier</key>
			<string>ABCD123456</string>
			<key>aps-environment</key>
			<string>development</string>
			<key>keychain-access-groups</key>
			<array>
				<string>ABCD123456.com.example.secretapp</string>
			</array>
		</dict>
		</plist>
		"""

	// MARK: - What the card keeps

	func testCardReportsOperationalFacts() {
		let card = makeHealth(entitlements: richEntitlements, revocation: .good).redactedHealthCard

		XCTAssertTrue(card.contains("OCSP status: Good"))
		XCTAssertTrue(card.contains("Provisioning profile expiry:"))
		XCTAssertTrue(card.contains("Signing certificate expiry:"))
		XCTAssertTrue(card.contains("Limited device profile (3 devices)"))
		// Entitlement names are useful for triage and are not secrets.
		XCTAssertTrue(card.contains("aps-environment"))
		XCTAssertTrue(card.contains("application-identifier"))
		XCTAssertTrue(card.contains("keychain-access-groups"))
	}

	func testEnterpriseProfileReportsAllDevicesScope() {
		let card = makeHealth(entitlements: richEntitlements, allDevices: true).redactedHealthCard

		XCTAssertTrue(card.contains("Device scope: All devices"))
		XCTAssertFalse(card.contains("Limited device profile"))
	}

	func testUnparsedEntitlementsStillProduceACard() {
		let card = makeHealth(entitlements: "not a plist at all").redactedHealthCard

		XCTAssertTrue(card.contains("Entitlements: None parsed"))
		XCTAssertTrue(card.contains("OCSP status: Unknown"))
	}

	// MARK: - What the card must never leak

	func testCardOmitsIdentifiersAndEntitlementValues() {
		let card = makeHealth(entitlements: richEntitlements).redactedHealthCard

		XCTAssertFalse(card.contains("ABCD123456"))
		XCTAssertFalse(card.contains("com.example.secretapp"))
		XCTAssertFalse(card.contains("00008030-001A2B3C4D5E6F70"))
		XCTAssertFalse(card.contains("Example Team Ltd"))
		XCTAssertFalse(card.contains("development"))
		// The group *name* may appear for triage; its value must not.
		XCTAssertFalse(card.contains("ABCD123456.com.example.secretapp"))
	}

	func testCardOmitsProfilePayloadAndCertificateDetails() {
		let health = makeHealth(entitlements: richEntitlements)
		let card = health.redactedHealthCard

		XCTAssertFalse(card.contains(health.provision))
		XCTAssertFalse(card.contains("<?xml"))
		XCTAssertFalse(card.contains("ProvisionedDevices"))
		XCTAssertFalse(card.contains(health.id))
		XCTAssertFalse(card.contains(health.name))
		XCTAssertFalse(card.contains(health.detail))
	}

	func testCardStatesThatUDIDMatchWasNotAssessed() {
		// "Not assessed" must not be mistaken for a verified device match.
		let card = makeHealth(entitlements: richEntitlements).redactedHealthCard

		XCTAssertTrue(card.contains("Device UDID match: Not assessed by this report"))
		XCTAssertTrue(card.contains("OCSP Unknown does not mean valid"))
	}
}
