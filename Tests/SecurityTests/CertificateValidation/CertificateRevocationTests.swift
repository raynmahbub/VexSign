//
//  CertificateRevocationTests.swift
//  VexSignTests
//
//  Covers the revocation cache that replaced the third-party certificate checker
// : the OCSP-to-badge mapping, the freshness rule, the
//  shape of what is persisted — which must never be key material — and the
//  refusal to hand a p12 to the parked cloud-signing uploader.
//

import XCTest
@testable import VexSign

final class CertificateRevocationTests: XCTestCase {

	// MARK: - Status mapping

	func testOnlyPositiveOCSPEvidenceCountsAsSigned() {
		XCTAssertEqual(CertificateStatusValue(revocation: .good), .signed)
		XCTAssertEqual(CertificateStatusValue(revocation: .revoked), .revoked)
		XCTAssertEqual(CertificateStatusValue(revocation: .unknown), .unknown)
	}

	func testUnknownKeepsItsOwnTitleInsteadOfLookingVerified() {
		let unknown = CertificateRevocationSnapshot(
			status: .unknown,
			detail: "OCSP has not been checked.",
			checkedAt: Date()
		)
		XCTAssertEqual(unknown.displayTitle, CertificateStatusValue.unknown.title)
		XCTAssertNotEqual(unknown.displayTitle, CertificateRevocationSnapshot(
			status: .signed,
			detail: "System trust evaluation passed with positive OCSP evidence.",
			checkedAt: Date()
		).displayTitle)
	}

	// MARK: - Freshness

	func testVerdictIsReusedInsideTheWindowAndRefreshedOutsideIt() {
		let checkedAt = Date(timeIntervalSince1970: 1_000_000)
		let snapshot = CertificateRevocationSnapshot(status: .signed, detail: "ok", checkedAt: checkedAt)

		XCTAssertTrue(snapshot.isFresh(now: checkedAt.addingTimeInterval(29 * 60)))
		XCTAssertTrue(snapshot.isFresh(now: checkedAt.addingTimeInterval(30 * 60)))
		XCTAssertFalse(snapshot.isFresh(now: checkedAt.addingTimeInterval(31 * 60)))
	}

	func testClockSkewDoesNotMakeAVerdictEternallyFresh() {
		// The cache compares absolute distance, so a device clock moved back a day
		// does not pin an old "signed" verdict forever.
		let snapshot = CertificateRevocationSnapshot(
			status: .signed,
			detail: "ok",
			checkedAt: Date(timeIntervalSince1970: 2_000_000)
		)
		XCTAssertFalse(snapshot.isFresh(now: Date(timeIntervalSince1970: 2_000_000 - 86_400)))
	}

	// MARK: - Persistence shape

	// MARK: - No private key leaves the device

	@MainActor
	func testCloudSigningRefusesToUploadAPrivateKey() async throws {
		let file = FileManager.default.temporaryDirectory
			.appendingPathComponent("refusal-\(UUID().uuidString).p12")
		try Data("not a real p12".utf8).write(to: file)
		defer { try? FileManager.default.removeItem(at: file) }

		do {
			_ = try await CloudSigningClient.shared.upload(fileURL: file, kind: .p12)
			XCTFail("A p12 must never be uploaded, signed remotely or not")
		} catch {
			XCTAssertEqual(error as? CloudSigningError, .privateKeyUploadDisabled)
		}
	}

	@MainActor
	func testCloudSigningEntryPointIsClosedToo() async throws {
		let storage = Storage(inMemory: true)
		let id = try await storage.write { context in
			let certificate = CertificatePair(context: context)
			certificate.uuid = "refusal-\(UUID().uuidString)"
			certificate.date = Date()
			// Non-optional in the model, so set them instead of relying on defaults.
			certificate.ppQCheck = false
			certificate.isDefault = false
			certificate.revoked = false
			return certificate
		}
		let certificate: CertificatePair = try XCTUnwrap(storage.object(id))
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("app.ipa")

		do {
			_ = try await CloudSigningClient.shared.signRemotely(ipaURL: url, cert: certificate, progress: { _, _ in })
			XCTFail("Remote signing must not start while the consent surface does not exist")
		} catch {
			XCTAssertEqual(error as? CloudSigningError, .privateKeyUploadDisabled)
		}
	}

	func testSnapshotPersistsOnlyAVerdictSentenceAndDate() throws {
		let snapshot = CertificateRevocationSnapshot(
			status: .revoked,
			detail: "The certificate has been revoked.",
			checkedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)

		let data = try JSONEncoder().encode(["uuid": snapshot])
		let json = try XCTUnwrap(String(data: data, encoding: .utf8))

		// Nothing that could carry a private key or its password.
		for forbidden in ["p12", "P12", "BEGIN", "password", "passphrase", "certificate.p12"] {
			XCTAssertFalse(
				json.contains(forbidden),
				"The cache must not grow key material — found \(forbidden): \(json)"
			)
		}

		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
		let entry = try XCTUnwrap(object["uuid"])
		XCTAssertEqual(Set(entry.keys), ["status", "detail", "checkedAt"])

		let decoded = try JSONDecoder().decode([String: CertificateRevocationSnapshot].self, from: data)
		XCTAssertEqual(decoded["uuid"], snapshot)
	}
}
