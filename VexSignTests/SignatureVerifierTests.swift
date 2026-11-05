//
//  SignatureVerifierTests.swift
//  VexSignTests
//
//  Fixture-based tests for. No private key and no device: the fixtures are synthetic
//  bundles whose executables carry a real `LC_CODE_SIGNATURE` load command and a real
//  entitlements superblob, which is exactly what the verifier reads.
//
//  The acceptance cases are here by name: deleting
//  `_CodeSignature` must fail, and a profile for an unrelated App ID must fail.
//

import XCTest
@testable import VexSign

final class SignatureVerifierTests: XCTestCase {
	private var _root: URL!

	override func setUpWithError() throws {
		_root = FileManager.default.temporaryDirectory
			.appendingPathComponent("SignatureVerifierTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: _root, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let _root {
			try? FileManager.default.removeItem(at: _root)
		}
		_root = nil
	}

	// MARK: - Acceptance cases

	func testACleanlySignedBundleIsAcceptable() throws {
		let bundle = try _makeBundle()

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertEqual(report.bundlePath, bundle.path)
		XCTAssertTrue(report.failures.isEmpty, _describe(report))
		XCTAssertTrue(report.isAcceptable, _describe(report))
	}

	func testDeletingCodeResourcesIsAFailure() throws {
		let bundle = try _makeBundle()
		try FileManager.default.removeItem(at: bundle.appendingPathComponent("_CodeSignature"))

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertFalse(report.isAcceptable)
		XCTAssertTrue(report.failures.contains { $0.code == .missingCodeResources }, _describe(report))
	}

	func testAProfileForAnotherAppIsAFailure() throws {
		let bundle = try _makeBundle(
			profileEntitlements: ["application-identifier": "TEAM99999.com.someone.else"]
		)

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertFalse(report.isAcceptable)
		XCTAssertTrue(report.failures.contains { $0.code == .bundleIdentifierMismatch }, _describe(report))
	}

	// MARK: - Profile coverage

	func testAWildcardProfileCoversTheApp() throws {
		let bundle = try _makeBundle(profileEntitlements: ["application-identifier": "TEAM12345.*"])

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertTrue(report.isAcceptable, _describe(report))
	}

	func testAPrefixWildcardProfileCoversTheApp() throws {
		let bundle = try _makeBundle(profileEntitlements: ["application-identifier": "TEAM12345.com.example.*"])

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertTrue(report.isAcceptable, _describe(report))
	}

	func testAnExpiredProfileIsAFailure() throws {
		let bundle = try _makeBundle(profileExpiry: Date().addingTimeInterval(-60 * 60 * 24))

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertFalse(report.isAcceptable)
		XCTAssertTrue(report.failures.contains { $0.code == .profileExpired }, _describe(report))
	}

	func testAMissingProfileFailsOnlyWhenOneWasExpected() throws {
		let bundle = try _makeBundle(writesProfile: false)

		let expected = SignatureVerifier.verify(bundleAt: bundle, expectation: .freshlySigned)
		XCTAssertTrue(expected.failures.contains { $0.code == .profileMissing }, _describe(expected))

		let tolerated = SignatureVerifier.verify(bundleAt: bundle, expectation: .alreadySigned)
		XCTAssertFalse(
			tolerated.failures.contains { $0.code == .profileMissing },
			"an already-signed bundle may legitimately have no profile"
		)
	}

	// MARK: - Entitlements

	func testAnEntitlementTheProfileDoesNotGrantIsAFailure() throws {
		let bundle = try _makeBundle(
			executableEntitlements: [
				"application-identifier": "TEAM12345.com.example.app",
				"aps-environment": "production"
			]
		)

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertFalse(report.isAcceptable)
		XCTAssertTrue(report.failures.contains { $0.code == .entitlementNotGranted }, _describe(report))
	}

	func testAToleratedEntitlementIsOnlyAWarning() throws {
		// VexSign rewrites keychain-access-groups itself; a difference there must not block.
		let bundle = try _makeBundle(
			executableEntitlements: [
				"application-identifier": "TEAM12345.com.example.app",
				"keychain-access-groups": ["TEAM12345.com.example.isolated"]
			]
		)

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertTrue(report.isAcceptable, _describe(report))
		XCTAssertTrue(report.warnings.contains { $0.code == .entitlementNotGranted }, _describe(report))
	}

	func testAnAppGroupTheProfileDoesNotGrantIsAFailure() throws {
		let bundle = try _makeBundle(
			executableEntitlements: [
				"application-identifier": "TEAM12345.com.example.app",
				"com.apple.security.application-groups": ["group.com.example.shared"]
			]
		)

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertFalse(report.isAcceptable)
		XCTAssertTrue(report.failures.contains { $0.code == .entitlementNotGranted }, _describe(report))
	}

	func testJITEntitlementsAreTolerated() throws {
		// VexSign adds these itself for PPQ certificates; a profile never lists them, and
		// reporting them as failures would block every JIT-enabled sign.
		let bundle = try _makeBundle(
			executableEntitlements: [
				"application-identifier": "TEAM12345.com.example.app",
				"dynamic-codesigning": true,
				"com.apple.security.cs.allow-jit": true
			]
		)

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertTrue(report.isAcceptable, _describe(report))
	}

	// MARK: - Identifier the user asked for

	func testABundleThatKeptItsOldIdentifierIsAFailure() throws {
		let bundle = try _makeBundle()
		var expectation = SignatureVerifier.Expectation.freshlySigned
		expectation.declaredBundleIdentifier = "com.example.requested"

		let report = SignatureVerifier.verify(bundleAt: bundle, expectation: expectation)

		XCTAssertFalse(report.isAcceptable)
		XCTAssertTrue(report.failures.contains { $0.code == .bundleIdentifierMismatch }, _describe(report))
	}

	func testAnUnsignedExecutableIsAFailure() throws {
		let bundle = try _makeBundle(signsExecutable: false)

		let report = SignatureVerifier.verify(bundleAt: bundle)

		XCTAssertFalse(report.isAcceptable)
		XCTAssertTrue(report.failures.contains { $0.code == .unsignedExecutable }, _describe(report))
	}

	func testADirectoryWithNoBundleIsNotAcceptable() throws {
		let report = SignatureVerifier.verify(bundleAt: _root)

		XCTAssertNil(report.bundlePath)
		XCTAssertFalse(report.isAcceptable)
		XCTAssertTrue(report.failures.contains { $0.code == .bundleNotFound }, _describe(report))
	}

	// MARK: - Performance

	func testVerificationIsCheapEnoughToRunOnEverySign() throws {
		let bundle = try _makeBundle()

		let started = Date()
		_ = SignatureVerifier.verify(bundleAt: bundle)
		let elapsed = Date().timeIntervalSince(started)

		// The roadmap's budget is ~200 ms for a 200 MB bundle on device. This fixture is tiny,
		// so anything approaching half a second here means the verifier is walking the bundle
		// instead of reading headers.
		XCTAssertLessThan(elapsed, 0.5, "verification took \(elapsed)s on a two-file bundle")
	}

	// MARK: - Coverage rules

	func testCoverageRulesMatchAppleSemantics() {
		XCTAssertTrue(SignatureVerifier.coverage(of: "TEAM.com.example.app", includes: "com.example.app"))
		XCTAssertTrue(SignatureVerifier.coverage(of: "TEAM.*", includes: "com.example.app"))
		XCTAssertTrue(SignatureVerifier.coverage(of: "TEAM.com.example.*", includes: "com.example.app"))
		XCTAssertTrue(SignatureVerifier.coverage(of: "TEAM.com.example.*", includes: "com.example.other"))

		// An entitlement value carries the team prefix; a bundle identifier does not. Both are
		// legitimate inputs, so both resolve to the same answer.
		XCTAssertTrue(SignatureVerifier.coverage(of: "TEAM.com.example.app", includes: "TEAM.com.example.app"))

		XCTAssertFalse(SignatureVerifier.coverage(of: "TEAM.com.example.app", includes: "com.example.other"))
		XCTAssertFalse(SignatureVerifier.coverage(of: "TEAM.com.example.*", includes: "com.examplex.app"))
		XCTAssertFalse(
			SignatureVerifier.coverage(of: "TEAM.com.example.app", includes: "com.example.app.extension"),
			"an explicit App ID does not cover its extensions"
		)
		XCTAssertTrue(
			SignatureVerifier.coverage(of: "com.example.app", includes: "com.example.app"),
			"a pattern with no team prefix is compared literally"
		)
	}

	func testWildcardDetection() {
		XCTAssertTrue(SignatureVerifier.isWildcard("TEAM.*"))
		XCTAssertTrue(SignatureVerifier.isWildcard("TEAM.com.example.*"))
		XCTAssertFalse(SignatureVerifier.isWildcard("TEAM.com.example.app"))
		XCTAssertFalse(SignatureVerifier.isWildcard("com.example.app"))
	}

	// MARK: - Fixtures

	private func _describe(_ report: SignatureVerifier.Report) -> String {
		"issues: " + report.issues.map { "\($0.code.rawValue)[\($0.severity.rawValue)] \($0.detail)" }.joined(separator: " | ")
	}

	@discardableResult
	private func _makeBundle(
		identifier: String = "com.example.app",
		executableEntitlements: [String: Any] = ["application-identifier": "TEAM12345.com.example.app"],
		profileEntitlements: [String: Any]? = nil,
		profileExpiry: Date = Date().addingTimeInterval(60 * 60 * 24 * 30),
		signsExecutable: Bool = true,
		writesCodeResources: Bool = true,
		writesProfile: Bool = true
	) throws -> URL {
		let fm = FileManager.default
		let bundle = _root.appendingPathComponent("App.app", isDirectory: true)
		try fm.createDirectory(at: bundle, withIntermediateDirectories: true)

		let info: [String: Any] = [
			"CFBundleIdentifier": identifier,
			"CFBundleExecutable": "App",
			"CFBundleName": "App",
			"CFBundlePackageType": "APPL",
			"CFBundleShortVersionString": "1.0"
		]
		try _plist(info).write(to: bundle.appendingPathComponent("Info.plist"))

		try _machO(entitlements: signsExecutable ? executableEntitlements : nil)
			.write(to: bundle.appendingPathComponent("App"))

		if writesCodeResources {
			let signature = bundle.appendingPathComponent("_CodeSignature", isDirectory: true)
			try fm.createDirectory(at: signature, withIntermediateDirectories: true)
			try _plist(["files": ["App": [:] as [String: Any]]])
				.write(to: signature.appendingPathComponent("CodeResources"))
		}

		if writesProfile {
			let entitlements = profileEntitlements ?? ["application-identifier": "TEAM12345.\(identifier)"]
			try _plist(
				_profile(identifier: identifier, entitlements: entitlements, expiry: profileExpiry)
			).write(to: bundle.appendingPathComponent("embedded.mobileprovision"))
		}

		return bundle
	}

	private func _profile(identifier: String, entitlements: [String: Any], expiry: Date) -> [String: Any] {
		[
			"AppIDName": identifier,
			"ApplicationIdentifierPrefix": ["TEAM12345"],
			"CreationDate": Date().addingTimeInterval(-60 * 60 * 24),
			"Platform": ["iOS"],
			"Entitlements": entitlements,
			"ExpirationDate": expiry,
			"Name": "Fixture Profile",
			"ProvisionsAllDevices": false,
			"TeamIdentifier": ["TEAM12345"],
			"TeamName": "Fixture Team",
			"TimeToLive": 365,
			"UUID": UUID().uuidString,
			"Version": 1
		]
	}

	/// A plist that `CertificateReader` accepts: it looks for `<?xml` and `</plist>` and decodes
	/// everything between them, so an unsigned XML plist exercises the same path as a CMS blob.
	private func _plist(_ dictionary: [String: Any]) throws -> Data {
		try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
	}

	/// A 64-bit Mach-O header whose single load command is `LC_CODE_SIGNATURE`, followed by a
	/// code signature superblob holding the entitlements. `MachOEntitlements` reads exactly this.
	private func _machO(entitlements: [String: Any]?) throws -> Data {
		let headerSize = 32
		let commandSize = 16

		var superblob = Data()
		if let entitlements {
			let plist = try _plist(entitlements)
			let entitlementsMagic: UInt32 = 0xfade_7171
			let superblobMagic: UInt32 = 0xfade_0cc0
			let entitlementsSlot: UInt32 = 5

			var blob = Data()
			blob.append(_u32(entitlementsMagic))
			blob.append(_u32(UInt32(8 + plist.count)))
			blob.append(plist)

			superblob.append(_u32(superblobMagic))
			superblob.append(_u32(UInt32(12 + 8 + blob.count)))
			superblob.append(_u32(1))
			superblob.append(_u32(entitlementsSlot))
			superblob.append(_u32(20))
			superblob.append(blob)
		}

		// An arm64 Mach-O is little-endian throughout, including the magic; only the code
		// signature superblob is big-endian.
		var data = Data()
		data.append(_u32le(0xfeed_facf)) // MH_MAGIC_64
		data.append(_u32le(0x0100_000c)) // CPU_TYPE_ARM64
		data.append(_u32le(0))           // cpusubtype
		data.append(_u32le(2))           // MH_EXECUTE
		data.append(_u32le(1))           // ncmds
		data.append(_u32le(UInt32(commandSize)))
		data.append(_u32le(0))           // flags
		data.append(_u32le(0))           // reserved

		if entitlements == nil {
			// A load command that is *not* a code signature: the binary is unsigned.
			data.append(_u32le(0x19))    // LC_SEGMENT_64
			data.append(_u32le(UInt32(commandSize)))
		} else {
			data.append(_u32le(0x1d))    // LC_CODE_SIGNATURE
			data.append(_u32le(UInt32(commandSize)))
			data.append(_u32le(UInt32(headerSize + commandSize)))
			data.append(_u32le(UInt32(superblob.count)))
		}

		data.append(superblob)
		return data
	}

	/// Big-endian, for the code signature superblob (which is always big-endian).
	private func _u32(_ value: UInt32) -> Data {
		var bigEndian = value.bigEndian
		return withUnsafeBytes(of: &bigEndian) { Data($0) }
	}

	/// Little-endian, for arm64 Mach-O headers and load commands.
	private func _u32le(_ value: UInt32) -> Data {
		var littleEndian = value.littleEndian
		return withUnsafeBytes(of: &littleEndian) { Data($0) }
	}
}
