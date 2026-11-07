//
//  ZsignEngineTests.swift
//  VexSignTests
//
//  Tests for the seam between VexSign and the pinned `zsign` engine.
//
//  The engine itself is C++ linked into the app, so it is not invoked here — these tests cover
//  the parts that are VexSign's own and that a bad edit can silently invert: the provisioning
//  flag handed to the engine, the shape of a request, and the cache directory the handler clears
//  before every run.
//

import Foundation
import XCTest
@testable import VexSign

final class ZsignEngineTests: XCTestCase {
	private var workDirectory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		workDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ZsignEngineTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		if let workDirectory {
			try? FileManager.default.removeItem(at: workDirectory)
		}
		workDirectory = nil
		try super.tearDownWithError()
	}

	// MARK: - Provisioning polarity

	/// The pin writes `embedded.mobileprovision` when the engine flag is `true`
	/// (`src/bundle.cpp:536-544`), while `Options.removeProvisioning` means the opposite. The
	/// translation happens once, in `Request.engineEmbedProvision`, and this is what pins it.
	func testTheProfileIsEmbeddedUnlessTheOptionRemovesIt() {
		let keepsProfile = ZsignEngine.Request(appPath: "/tmp/A.app", removeProvisioning: false)
		XCTAssertTrue(keepsProfile.engineEmbedProvision)

		let dropsProfile = ZsignEngine.Request(appPath: "/tmp/A.app", removeProvisioning: true)
		XCTAssertFalse(dropsProfile.engineEmbedProvision)
	}

	/// The option defaults to *keeping* the profile, as the engine does.
	func testAnUntouchedRequestSignsWithAProfile() {
		let request = ZsignEngine.Request(appPath: "/tmp/A.app")
		XCTAssertFalse(request.removeProvisioning)
		XCTAssertTrue(request.engineEmbedProvision)
		XCTAssertFalse(request.isAdHoc)
	}

	/// The signer and the post-sign verifier are told the same thing from the same option
	/// (`SigningHandler._verifySignedBundle`). If one of them starts reading the flag the other
	/// way round, a good bundle fails verification or a profile-less one passes it.
	func testTheVerifierExpectsWhatTheEngineWasToldToProduce() {
		for removeProvisioning in [false, true] {
			let request = ZsignEngine.Request(
				appPath: "/tmp/A.app",
				removeProvisioning: removeProvisioning
			)
			var expectation = SignatureVerifier.Expectation.freshlySigned
			expectation.requiresEmbeddedProfile = !removeProvisioning

			XCTAssertEqual(request.engineEmbedProvision, expectation.requiresEmbeddedProfile)
		}
	}

	/// Only the provisioning intent changes between the two requests: the flag is not standing in
	/// for anything else.
	func testTheOnlyDifferenceBetweenTheTwoRequestsIsTheIntent() {
		let keepsProfile = ZsignEngine.Request(appPath: "/tmp/A.app", removeProvisioning: false)
		let dropsProfile = ZsignEngine.Request(appPath: "/tmp/A.app", removeProvisioning: true)

		XCTAssertNotEqual(keepsProfile, dropsProfile)
		XCTAssertEqual(keepsProfile.appPath, dropsProfile.appPath)
		XCTAssertEqual(keepsProfile.isAdHoc, dropsProfile.isAdHoc)
		XCTAssertEqual(keepsProfile.p12Path, dropsProfile.p12Path)
	}

	// MARK: - Request shape

	func testAnIdentityRequestCarriesEveryPathTheEngineNeeds() {
		let request = ZsignEngine.Request(
			appPath: "/tmp/A.app",
			provisionPath: "/tmp/a.mobileprovision",
			p12Path: "/tmp/a.p12",
			p12Password: "secret",
			entitlementsPath: "/tmp/a.entitlements",
			customIdentifier: "com.example.a",
			customName: "A",
			customVersion: "1.2.3",
			isAdHoc: false,
			removeProvisioning: false
		)

		XCTAssertEqual(request.appPath, "/tmp/A.app")
		XCTAssertEqual(request.provisionPath, "/tmp/a.mobileprovision")
		XCTAssertEqual(request.p12Path, "/tmp/a.p12")
		XCTAssertEqual(request.p12Password, "secret")
		XCTAssertEqual(request.entitlementsPath, "/tmp/a.entitlements")
		XCTAssertEqual(request.customIdentifier, "com.example.a")
		XCTAssertEqual(request.customName, "A")
		XCTAssertEqual(request.customVersion, "1.2.3")
	}

	/// Ad-hoc signing has no identity to point at, and the handler must not invent one.
	func testAnAdHocRequestHasNoIdentity() {
		var request = ZsignEngine.Request(appPath: "/tmp/A.app", isAdHoc: true)
		request.entitlementsPath = "/tmp/a.entitlements"

		XCTAssertTrue(request.isAdHoc)
		XCTAssertTrue(request.p12Path.isEmpty)
		XCTAssertTrue(request.provisionPath.isEmpty)
		XCTAssertTrue(request.p12Password.isEmpty)
	}

	// MARK: - Identity

	/// `ZSignAsset::Init` fails — and `zsign.mm` then returns -1 without calling its completion
	/// handler, which is where the bare "Signing failed." came from — for a missing profile, an
	/// unreadable profile, an unusable .p12, a profile without a team, and a profile that does
	/// not name the .p12's certificate. Each case now has a sentence instead.
	func testAMissingProfileIsNamedAsSuch() {
		XCTAssertEqual(
			ZsignEngine.identityProblem(provisioningProfile: nil, certificate: Data([0x01]), leafCertificate: nil, profile: nil),
			.missingProvisioningProfile
		)
		XCTAssertEqual(
			ZsignEngine.identityProblem(provisioningProfile: Data(), certificate: Data([0x01]), leafCertificate: nil, profile: nil),
			.missingProvisioningProfile
		)
	}

	func testAMissingCertificateIsNamedAsSuch() {
		XCTAssertEqual(
			ZsignEngine.identityProblem(provisioningProfile: Data([0x01]), certificate: nil, leafCertificate: nil, profile: nil),
			.missingCertificate
		)
	}

	func testAnUnreadableProfileIsNamedAsSuch() {
		XCTAssertEqual(
			ZsignEngine.identityProblem(provisioningProfile: Data([0x01]), certificate: Data([0x02]), leafCertificate: nil, profile: nil),
			.profileUnreadable
		)
	}

	func testAProfileWithoutATeamIsNamedAsSuch() {
		let profile = _profile(team: "")

		XCTAssertEqual(
			ZsignEngine.identityProblem(
				provisioningProfile: Data([0x01]),
				certificate: Data([0x02]),
				leafCertificate: nil,
				profile: profile
			),
			.missingTeamIdentifier
		)
	}

	/// A .p12 that does not open with the stored password yields no leaf certificate.
	func testACertificateThatDoesNotOpenIsNamedAsSuch() {
		XCTAssertEqual(
			ZsignEngine.identityProblem(
				provisioningProfile: Data([0x01]),
				certificate: Data([0x02]),
				leafCertificate: nil,
				profile: _profile()
			),
			.unreadableCertificate
		)
		XCTAssertEqual(
			ZsignEngine.identityProblem(
				provisioningProfile: Data([0x01]),
				certificate: Data([0x02]),
				leafCertificate: Data(),
				profile: _profile()
			),
			.unreadableCertificate
		)
	}

	/// A profile that names certificates, none of which is this one: the engine's
	/// "Can't find paired certificate and private key!", which is the usual personal-certificate
	/// mistake of importing a profile and a .p12 from different sources.
	func testAProfileThatDoesNotNameTheCertificateIsNamedAsSuch() {
		let leaf = Data([0xAA, 0xBB, 0xCC])
		let other = Data([0x01, 0x02, 0x03])

		XCTAssertEqual(
			ZsignEngine.identityProblem(
				provisioningProfile: Data([0x01]),
				certificate: Data([0x02]),
				leafCertificate: leaf,
				profile: _profile(developerCertificates: [other])
			),
			.certificateNotInProfile
		)

		XCTAssertNil(
			ZsignEngine.identityProblem(
				provisioningProfile: Data([0x01]),
				certificate: Data([0x02]),
				leafCertificate: leaf,
				profile: _profile(developerCertificates: [other, leaf])
			),
			"a profile that names this certificate can sign with it"
		)
	}

	func testAProfileThatNamesNoCertificatesSkipsTheComparison() {
		XCTAssertNil(
			ZsignEngine.identityProblem(
				provisioningProfile: Data([0x01]),
				certificate: Data([0x02]),
				leafCertificate: Data([0xAA, 0xBB, 0xCC]),
				profile: _profile()
			),
			"an older profile without DeveloperCertificates cannot be compared and must not block"
		)
	}

	// MARK: - Cache

	/// The engine builds its cache path from `.` (`src/bundle.cpp:557-598`), i.e. from the
	/// working directory it was started in, not from the bundle it signs.
	func testTheCacheLivesInTheWorkingDirectory() {
		let directory = URL(fileURLWithPath: "/tmp/vexsign-work", isDirectory: true)
		XCTAssertEqual(
			ZsignEngine.cacheDirectory(in: directory).path,
			"/tmp/vexsign-work/\(ZsignEngine.cacheDirectoryName)"
		)
		XCTAssertEqual(ZsignEngine.cacheDirectoryName, ".zsign_cache")
	}

	func testClearingTheCacheRemovesTheDirectoryAndNothingElse() throws {
		let cache = ZsignEngine.cacheDirectory(in: workDirectory)
		try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
		try Data("{}".utf8).write(to: cache.appendingPathComponent("0a1b2c.json"))

		let neighbour = workDirectory.appendingPathComponent("sign.log")
		try Data("kept".utf8).write(to: neighbour)

		XCTAssertTrue(ZsignEngine.clearCache(in: workDirectory))
		XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
	}

	func testClearingACleanDirectoryReportsNothingToDo() {
		XCTAssertFalse(ZsignEngine.clearCache(in: workDirectory))
	}

	/// Clearing twice in a row is what a second signing run does; the second run must not fail
	/// because the first one already tidied up.
	func testTheCacheCanBeClearedTwice() throws {
		let cache = ZsignEngine.cacheDirectory(in: workDirectory)
		try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

		XCTAssertTrue(ZsignEngine.clearCache(in: workDirectory))
		XCTAssertFalse(ZsignEngine.clearCache(in: workDirectory))
	}

	// MARK: - Fixtures

	private func _profile(
		team: String = "TEAM12345",
		developerCertificates: [Data]? = nil
	) -> Certificate {
		Certificate(
			AppIDName: "Fixture",
			ApplicationIdentifierPrefix: [team],
			CreationDate: Date().addingTimeInterval(-60 * 60 * 24),
			Platform: ["iOS"],
			IsXcodeManaged: nil,
			DeveloperCertificates: developerCertificates,
			derEncodedProfile: nil,
			PPQCheck: nil,
			Entitlements: ["application-identifier": AnyCodable("TEAM12345.com.example.app")],
			ExpirationDate: Date().addingTimeInterval(60 * 60 * 24 * 30),
			Name: "Fixture Profile",
			ProvisionsAllDevices: false,
			ProvisionedDevices: nil,
			TeamIdentifier: [team],
			TeamName: "Fixture Team",
			TimeToLive: 365,
			UUID: "FIXTURE-PROFILE",
			Version: 1
		)
	}
}
