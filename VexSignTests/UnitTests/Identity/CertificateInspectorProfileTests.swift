//
//  CertificateInspectorProfileTests.swift
//  VexSignTests
//
//  `CertificateInspector.inspect` parses a `.mobileprovision` that the user picked
//  from anywhere — Files, a shared link, another app. Everything it reads is
//  untrusted, and the refusals below are what keeps a malformed profile from being
//  reported as a healthy certificate. None of this had coverage.
//

import XCTest
@testable import VexSign

final class CertificateInspectorProfileTests: XCTestCase {

	private var directory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("vexsign-inspector-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let directory { try? FileManager.default.removeItem(at: directory) }
		try super.tearDownWithError()
	}

	@discardableResult
	private func write(_ data: Data, name: String) throws -> URL {
		let url = directory.appendingPathComponent(name)
		try data.write(to: url)
		return url
	}

	private func plistData(_ values: [String: Any]) throws -> Data {
		try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
	}

	private func inspect(profile: URL, p12: URL? = nil) async throws -> CertificateHealth {
		let keyURL = try write(Data([0x00, 0x01, 0x02, 0x03]), name: "noise.p12")
		return try await CertificateInspector.inspect(
			id: "test",
			name: "Test",
			p12: p12 ?? keyURL,
			password: "not-the-password",
			profile: profile,
			online: false
		)
	}

	private func assertProfileInvalid(_ profile: URL, messageContains expected: String? = nil) async {
		do {
			_ = try await inspect(profile: profile)
			XCTFail("a profile that is not a profile must not be reported as healthy")
		} catch {
			guard let repositoryError = error as? RepositoryError else {
				return XCTFail("expected a RepositoryError, got \(type(of: error))")
			}
			guard case .invalid(let message) = repositoryError else {
				return XCTFail("expected .invalid, got \(repositoryError)")
			}
			if let expected { XCTAssertTrue(message.contains(expected), message) }
		}
	}

	func testPayloadWithoutAPlistEnvelopeIsRefused() async throws {
		let profile = try write(Data("not a profile at all".utf8), name: "random.mobileprovision")
		await assertProfileInvalid(profile, messageContains: "Invalid provisioning profile")
	}

	func testTruncatedPlistIsRefused() async throws {
		// `<?xml` present, closing tag missing: the substring window would otherwise
		// hand a truncated plist to the serialiser.
		let profile = try write(Data("<?xml version=\"1.0\"?><plist><dict>".utf8), name: "truncated.mobileprovision")
		await assertProfileInvalid(profile, messageContains: "Invalid provisioning profile")
	}

	func testProfileWithoutAnExpiryIsRefused() async throws {
		let profile = try write(try plistData(["TeamName": "Example"]), name: "no-expiry.mobileprovision")
		await assertProfileInvalid(profile, messageContains: "no expiration date")
	}

	func testOversizedProfileIsRefusedBeforeItIsParsed() async throws {
		// 10 MB is the documented ceiling in `CertificateInputReader`; a file at that
		// size must fail as too large rather than reach PropertyListSerialization.
		let oversized = Data(repeating: 0x00, count: CertificateInputReader.maximumBytes + 1)
		let profile = try write(oversized, name: "oversized.mobileprovision")
		do {
			_ = try await inspect(profile: profile)
			XCTFail("an oversized profile must not be read")
		} catch {
			XCTAssertEqual(error as? CertificateInputReader.ReadError, .tooLarge)
		}
	}

	func testValidProfileStillFailsWhenTheKeyFileIsNotAP12() async throws {
		// Past the profile checks the inspector imports the key pair. Garbage must
		// surface as a failure — never as a certificate with unknown dates.
		let payload: [String: Any] = [
			"ExpirationDate": Date(timeIntervalSince1970: 1_800_000_000),
			"TeamName": "Example Team",
			"TeamIdentifier": ["ABCDE12345"],
			"ProvisionedDevices": ["00008030-0011223344556677"],
			"Entitlements": ["application-identifier": "ABCDE12345.com.example.app", "get-task-allow": true]
		]
		let profile = try write(try plistData(payload), name: "valid.mobileprovision")
		do {
			_ = try await inspect(profile: profile)
			XCTFail("a non-PKCS12 key file must not inspect successfully")
		} catch {
			XCTAssertTrue(error is SecureSecretStore.Failure,
			              "expected the PKCS#12 import to be the failure, got \(type(of: error))")
		}
	}
}
