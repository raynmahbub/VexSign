//
//  LocalTLSIdentityTests.swift
//  VexSignTests
//
//  Covers the local install server's identity: the digest
//  rule the build pins, the marker file it writes, and the checks a downloaded
//  identity has to pass before it replaces the one on disk.
//
//  No certificates are checked in here — the parsing paths that need real X.509
//  material are exercised by the checks themselves (junk in, refusal out).
//

import XCTest
@testable import VexSign

final class LocalTLSIdentityTests: XCTestCase {
	private let pem = """
	-----BEGIN PRIVATE KEY-----
	AAAA
	-----END PRIVATE KEY-----
	"""

	private let cert = """
	-----BEGIN CERTIFICATE-----
	BBBB
	-----END CERTIFICATE-----
	"""

	private let commonName = "127.0.0.1"

    func testCertificateSourceUsesActualContainment() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let device = root.appendingPathComponent("Application Support/TLS")
        let bundle = root.appendingPathComponent("VexSign.app")
        func source(_ url: URL) -> String {
            LocalTLSIdentity.diagnosticSource(for: url, deviceDirectory: device, bundleDirectory: bundle)
        }
        XCTAssertEqual(source(device.appendingPathComponent("server.crt")), "device-local")
        XCTAssertEqual(source(bundle.appendingPathComponent("server.crt")), "bundle")
        XCTAssertEqual(source(root.appendingPathComponent("Application Support/TLS-other/server.crt")), "other-local")
        XCTAssertEqual(source(root.appendingPathComponent("Documents/server.pem")), "other-local")
    }

	// MARK: - Digest

	/// The vector `Tools/Development/tls-pack-digest.py` produces for the same three
	/// inputs. If either implementation changes the rule, this fails.
	func testPackDigestMatchesTheBuildScriptVector() {
		XCTAssertEqual(
			LocalTLSIdentity.packDigest(pem: pem, cert: cert, commonName: commonName),
			"c13c21f42bf0e5fd2ffedde075974783dd83defd579d9d8a26e9ad43a0df3dab"
		)
	}

	func testPackDigestIgnoresSurroundingWhitespace() {
		let noisy = "\n\n  " + pem + "  \n\n"

		XCTAssertEqual(
			LocalTLSIdentity.packDigest(pem: noisy, cert: cert + "\n", commonName: " \(commonName) "),
			LocalTLSIdentity.packDigest(pem: pem, cert: cert, commonName: commonName)
		)
	}

	func testPackDigestCoversEveryField() {
		let base = LocalTLSIdentity.packDigest(pem: pem, cert: cert, commonName: commonName)

		XCTAssertNotEqual(base, LocalTLSIdentity.packDigest(pem: pem + "A", cert: cert, commonName: commonName))
		XCTAssertNotEqual(base, LocalTLSIdentity.packDigest(pem: pem, cert: cert + "A", commonName: commonName))
		XCTAssertNotEqual(base, LocalTLSIdentity.packDigest(pem: pem, cert: cert, commonName: "local.host"))
	}

	func testPackDigestIsLowercaseHexOfAFullSHA256() {
		let digest = LocalTLSIdentity.packDigest(pem: pem, cert: cert, commonName: commonName)

		XCTAssertEqual(digest.count, 64)
		XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
	}

	// MARK: - Marker

	func testParseMarkerReadsModeHostAndDigest() {
		let marker = LocalTLSIdentity.parseMarker("""
		mode=release
		cn=local.vexsign.test
		digest=sha256:abc123
		""")

		XCTAssertEqual(marker?.mode, .release)
		XCTAssertEqual(marker?.commonName, "local.vexsign.test")
		XCTAssertEqual(marker?.digest, "abc123")
	}

	func testParseMarkerAcceptsABareDigest() {
		let marker = LocalTLSIdentity.parseMarker("mode=development\ndigest=abc123\n")

		XCTAssertEqual(marker?.mode, .development)
		XCTAssertEqual(marker?.digest, "abc123")
	}

	func testParseMarkerIgnoresCommentsBlankLinesAndUnknownKeys() {
		let marker = LocalTLSIdentity.parseMarker("""
		# written by make deps
		
		mode=release
		fetched=2026-01-01T00:00:00Z
		cn=127.0.0.1
		""")

		XCTAssertEqual(marker?.mode, .release)
		XCTAssertEqual(marker?.commonName, "127.0.0.1")
		XCTAssertNil(marker?.digest)
	}

	func testParseMarkerNeedsAMode() {
		XCTAssertNil(LocalTLSIdentity.parseMarker("cn=127.0.0.1\n"))
		XCTAssertNil(LocalTLSIdentity.parseMarker(""))
	}

	func testParseMarkerReportsAnUnrecognisedModeAsUnknown() {
		XCTAssertEqual(LocalTLSIdentity.parseMarker("mode=production\n")?.mode, LocalTLSIdentity.Mode.unknown)
	}

	// MARK: - Validation

	func testValidateRejectsEmptyMaterial() {
		XCTAssertThrows {
			_ = try LocalTLSIdentity.validate(pem: "", cert: cert, commonName: commonName)
		} matches: {
			if case .missingFiles = $0 { return true }
			return false
		}

		XCTAssertThrows {
			_ = try LocalTLSIdentity.validate(pem: pem, cert: " \n", commonName: commonName)
		} matches: {
			if case .missingFiles = $0 { return true }
			return false
		}
	}

	func testValidateRejectsAnUnusableHostname() {
		XCTAssertThrows {
			_ = try LocalTLSIdentity.validate(pem: pem, cert: cert, commonName: "not a host name")
		} matches: {
			if case .hostnameInvalid = $0 { return true }
			return false
		}
	}

	func testValidateRejectsAPackWithoutAKey() {
		XCTAssertThrows {
			_ = try LocalTLSIdentity.validate(pem: "nothing to see", cert: cert, commonName: commonName)
		} matches: {
			if case .keyMissing = $0 { return true }
			return false
		}
	}

	func testValidateRejectsACertificateSecurityCannotRead() {
		// Well-formed PEM, but the payload is not a certificate.
		XCTAssertThrows {
			_ = try LocalTLSIdentity.validate(pem: pem, cert: cert, commonName: commonName)
		} matches: {
			if case .noCertificates = $0 { return true }
			return false
		}
	}

	func testValidateRejectsAnEmptyCertificateBundle() {
		XCTAssertThrows {
			_ = try LocalTLSIdentity.validate(pem: pem, cert: "no pem here", commonName: commonName)
		} matches: {
			if case .noCertificates = $0 { return true }
			return false
		}
	}

	// MARK: - Hostnames

	func testNormalizedHostnameAcceptsTheShapesTheServerBindsTo() {
		XCTAssertEqual(ServerInstaller.normalizedHostname("127.0.0.1"), "127.0.0.1")
		XCTAssertEqual(ServerInstaller.normalizedHostname("local.example.test"), "local.example.test")
		XCTAssertEqual(ServerInstaller.normalizedHostname("  local.example.test \n"), "local.example.test")
		// A wildcard CN needs a concrete label that matches the certificate.
		XCTAssertEqual(ServerInstaller.normalizedHostname("*.example.test"), "local.example.test")
	}

	func testNormalizedHostnameRejectsWhatWouldBreakTheInstallURL() {
		XCTAssertNil(ServerInstaller.normalizedHostname("null"))
		XCTAssertNil(ServerInstaller.normalizedHostname(""))
		XCTAssertNil(ServerInstaller.normalizedHostname("two words"))
		XCTAssertNil(ServerInstaller.normalizedHostname("local.example.test:8443"))
		XCTAssertNil(ServerInstaller.normalizedHostname("local.example.test/path"))
		XCTAssertNil(ServerInstaller.normalizedHostname("user@local.example.test"))
	}

	// MARK: - Helpers

	private func XCTAssertThrows(
		_ body: () throws -> Void,
		matches predicate: (LocalTLSIdentity.Failure) -> Bool,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		do {
			try body()
			XCTFail("expected a failure", file: file, line: line)
		} catch {
			guard let failure = error as? LocalTLSIdentity.Failure else {
				return XCTFail("unexpected error \(error)", file: file, line: line)
			}
			XCTAssertTrue(predicate(failure), "unexpected failure \(failure)", file: file, line: line)
		}
	}
}
