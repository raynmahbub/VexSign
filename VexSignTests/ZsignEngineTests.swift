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
}
