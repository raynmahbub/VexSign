//
//  SourceProvenanceTests.swift
//  VexSignTests
//
//  a repository can prove itself. The tests sign with a real Ed25519 key (CryptoKit is
//  available in the test target) rather than stubbing the verifier, so the canonicalisation rule is
//  held to something, not just described.
//

import Foundation
import CryptoKit
import XCTest
@testable import VexSign

final class SourceProvenanceTests: XCTestCase {
	private let key = Curve25519.Signing.PrivateKey()

	// The store writes to `UserDefaults.standard`, which persists across tests in one process.
	override func setUp() {
		super.setUp()
		SourceProvenanceStore.clear()
	}

	override func tearDown() {
		SourceProvenanceStore.clear()
		super.tearDown()
	}

	// MARK: - Fixtures

	private func document(apps: [String] = ["com.example.one"], name: String = "Example Repo") -> [String: Any] {
		[
			"name": name,
			"identifier": "com.example.repo",
			"apps": apps.map { ["name": $0, "bundleIdentifier": $0, "developerName": "Example", "subtitle": "Sub", "localizedDescription": "Desc", "iconURL": "https://example.com/i.png", "tintColor": "000000", "versions": [["version": "1.0", "date": "2026-01-01", "downloadURL": "https://example.com/a.ipa", "size": 123]]] }
		]
	}

	private func data(_ object: [String: Any]) throws -> Data {
		try JSONSerialization.data(withJSONObject: object, options: [])
	}

	/// Signs the canonical form exactly as a publisher would.
	private func signed(_ object: [String: Any], publisher: String? = "Example") throws -> Data {
		let raw = try data(object)
		let canonical = try XCTUnwrap(SourceProvenanceVerifier.canonicalBytes(raw))
		let signature = try key.signature(for: canonical)

		var document = object
		var member: [String: Any] = [
			"algorithm": "ed25519",
			"publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
			"signature": signature.base64EncodedString()
		]
		if let publisher { member["publisher"] = publisher }
		document["vexsign"] = member
		return try data(document)
	}

	// MARK: - Unsigned

	func testADocumentWithoutASignatureIsUnsignedAndAccepted() throws {
		let provenance = SourceProvenanceVerifier.evaluate(try data(document()))

		XCTAssertEqual(provenance, .unsigned)
		XCTAssertTrue(provenance.isAcceptable)
		XCTAssertNil(provenance.badgeTitle)
	}

	func testNonJSONIsUnsignedRatherThanAnError() {
		XCTAssertEqual(SourceProvenanceVerifier.evaluate(Data("not json".utf8)), .unsigned)
	}

	// MARK: - Verified

	func testASignedDocumentVerifies() throws {
		let provenance = SourceProvenanceVerifier.evaluate(try signed(document()))

		XCTAssertEqual(provenance, .verified(publisher: "Example"))
		XCTAssertTrue(provenance.isAcceptable)
		XCTAssertEqual(provenance.badgeTitle, "Signed by Example")
	}

	func testASignedDocumentWithoutAPublisherStillVerifies() throws {
		let provenance = SourceProvenanceVerifier.evaluate(try signed(document(), publisher: nil))

		XCTAssertEqual(provenance, .verified(publisher: nil))
		XCTAssertEqual(provenance.badgeTitle, "Signed")
	}

	// MARK: - Tampering

	func testEditingASignedDocumentIsRejected() throws {
		let original = try signed(document())
		let member = try XCTUnwrap(SourceProvenanceVerifier.signature(in: original))

		var tampered = document()
		tampered["name"] = "Example Repo (modified)"
		tampered["vexsign"] = [
			"algorithm": member.algorithm,
			"publicKey": member.publicKey,
			"signature": member.signature,
			"publisher": member.publisher ?? ""
		]

		let provenance = SourceProvenanceVerifier.evaluate(try data(tampered))

		guard case .claimedButInvalid = provenance else {
			return XCTFail("a tampered document must not verify, got \(provenance)")
		}
		XCTAssertFalse(provenance.isAcceptable)
		XCTAssertEqual(provenance.badgeTitle, "Bad signature")
	}

	func testASignatureFromAnotherKeyIsRejected() throws {
		let other = Curve25519.Signing.PrivateKey()
		let raw = try data(document())
		let canonical = try XCTUnwrap(SourceProvenanceVerifier.canonicalBytes(raw))
		let signature = try other.signature(for: canonical)

		var document = document()
		document["vexsign"] = [
			"algorithm": "ed25519",
			"publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
			"signature": signature.base64EncodedString()
		]

		guard case .claimedButInvalid = SourceProvenanceVerifier.evaluate(try data(document)) else {
			return XCTFail("a signature from another key must not verify")
		}
	}

	// MARK: - Malformed claims

	func testUnknownAlgorithmIsRejectedWithSayingWhich() throws {
		var object = document()
		object["vexsign"] = [
			"algorithm": "rsa-sha1",
			"publicKey": "AAAA",
			"signature": "AAAA"
		]

		guard case .claimedButInvalid(let reason) = SourceProvenanceVerifier.evaluate(try data(object)) else {
			return XCTFail("expected a rejection")
		}
		XCTAssertTrue(reason.contains("rsa-sha1"), reason)
	}

	func testWrongSizedKeyIsRejected() throws {
		var object = document()
		object["vexsign"] = [
			"algorithm": "ed25519",
			"publicKey": Data(repeating: 1, count: 16).base64EncodedString(),
			"signature": Data(repeating: 2, count: 64).base64EncodedString()
		]

		guard case .claimedButInvalid(let reason) = SourceProvenanceVerifier.evaluate(try data(object)) else {
			return XCTFail("expected a rejection")
		}
		XCTAssertTrue(reason.localizedCaseInsensitiveContains("public key"), reason)
	}

	func testWrongSizedSignatureIsRejected() throws {
		var object = document()
		object["vexsign"] = [
			"algorithm": "ed25519",
			"publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
			"signature": Data(repeating: 2, count: 12).base64EncodedString()
		]

		guard case .claimedButInvalid = SourceProvenanceVerifier.evaluate(try data(object)) else {
			return XCTFail("expected a rejection")
		}
	}

	// MARK: - Canonicalisation

	func testCanonicalBytesIgnoreKeyOrderAndTheSignatureMember() throws {
		let one: [String: Any] = ["name": "A", "apps": [], "identifier": "x"]
		var two: [String: Any] = ["identifier": "x", "apps": [], "name": "A"]
		two["vexsign"] = ["algorithm": "ed25519", "publicKey": "k", "signature": "s"]

		let canonicalOne = try XCTUnwrap(SourceProvenanceVerifier.canonicalBytes(try data(one)))
		let canonicalTwo = try XCTUnwrap(SourceProvenanceVerifier.canonicalBytes(try data(two)))

		XCTAssertEqual(canonicalOne, canonicalTwo)
	}

	// MARK: - Store

	func testStoreRemembersAVerifiedPublisher() throws {
		let url = try XCTUnwrap(URL(string: "https://example.com/source.json"))

		SourceProvenanceStore.record(.verified(publisher: "Example"), for: url)
		XCTAssertEqual(SourceProvenanceStore.provenance(for: url), .verified(publisher: "Example"))

		SourceProvenanceStore.record(.claimedButInvalid(reason: "x"), for: url)
		XCTAssertFalse(try XCTUnwrap(SourceProvenanceStore.provenance(for: url)).isAcceptable)

		SourceProvenanceStore.record(.unsigned, for: url)
		XCTAssertNil(SourceProvenanceStore.provenance(for: url))

		SourceProvenanceStore.clear()
	}
}
