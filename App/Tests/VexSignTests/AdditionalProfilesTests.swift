//
//  AdditionalProfilesTests.swift
//  VexSignTests
//
//  Per-bundle provisioning profiles: which nested bundle gets which profile, and how that
//  changes what preflight reports as uncovered.
//

import Foundation
import XCTest
@testable import VexSign

final class AdditionalProfilesTests: XCTestCase {
	private let _main = "TEAM123456.com.example.app"
	private let _widget = "com.example.app.widget"

	func testAnExplicitMainProfileLeavesTheExtensionToItsOwnProfile() {
		let assigned = AdditionalProfiles.assignments(
			nestedIdentifiers: [_widget],
			mainPattern: _main,
			profiles: [(pattern: "TEAM123456.com.example.app.widget", value: "widget")]
		)
		XCTAssertEqual(assigned, [_widget: "widget"])
	}

	func testNothingIsAssignedWhenNoProfileCoversTheExtension() {
		let assigned = AdditionalProfiles.assignments(
			nestedIdentifiers: [_widget],
			mainPattern: _main,
			profiles: [(pattern: "TEAM123456.com.other.app", value: "other")]
		)
		XCTAssertTrue(assigned.isEmpty)
	}

	func testAWildcardMainProfileKeepsExtensionsUnlessAnExactProfileExists() {
		let unrelated = AdditionalProfiles.assignments(
			nestedIdentifiers: [_widget],
			mainPattern: "TEAM123456.*",
			profiles: [(pattern: "TEAM123456.com.example.*", value: "wild")]
		)
		XCTAssertTrue(unrelated.isEmpty, "A covering main profile must not be displaced by another wildcard.")

		let exact = AdditionalProfiles.assignments(
			nestedIdentifiers: [_widget],
			mainPattern: "TEAM123456.*",
			profiles: [(pattern: "TEAM123456.com.example.app.widget", value: "exact")]
		)
		XCTAssertEqual(exact, [_widget: "exact"])
	}

	func testAnExactProfileBeatsAnAdditionalWildcard() {
		let assigned = AdditionalProfiles.assignments(
			nestedIdentifiers: [_widget],
			mainPattern: _main,
			profiles: [
				(pattern: "TEAM123456.com.example.app.*", value: "wild"),
				(pattern: "TEAM123456.com.example.app.widget", value: "exact")
			]
		)
		XCTAssertEqual(assigned, [_widget: "exact"])
	}

	func testCoverageIsJudgedAcrossAllAdditionalPatterns() {
		let patterns = ["TEAM123456.com.other.app", "TEAM123456.com.example.app.widget"]
		XCTAssertTrue(AdditionalProfiles.covers(_widget, patterns: patterns))
		XCTAssertFalse(AdditionalProfiles.covers("com.example.app.share", patterns: patterns))
		XCTAssertFalse(AdditionalProfiles.covers(_widget, patterns: []))
	}

	func testImportRefusesProfilesThatCannotBeUsed() {
		let later = Date().addingTimeInterval(86_400)
		func problem(
			pattern: String? = "TEAM123456.com.example.app.widget",
			expires: Date? = nil,
			team: [String] = ["TEAM123456"],
			existing: [String] = []
		) -> AdditionalProfiles.ImportProblem? {
			AdditionalProfiles.importProblem(
				pattern: pattern,
				expirationDate: expires ?? later,
				teamIdentifiers: team,
				mainTeamIdentifiers: ["TEAM123456"],
				existingPatterns: existing
			)
		}

		XCTAssertNil(problem())
		XCTAssertEqual(problem(pattern: nil), .noApplicationIdentifier)
		XCTAssertEqual(problem(expires: Date().addingTimeInterval(-60)), .expired)
		XCTAssertEqual(problem(team: ["OTHERTEAM1"]), .differentTeam)
		XCTAssertEqual(problem(existing: ["TEAM123456.com.example.app.widget"]), .duplicate)
	}

	func testTheAuditTreatsAnExtensionWithItsOwnProfileAsCovered() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		let app = root.appendingPathComponent("Example.app")
		let widget = app.appendingPathComponent("PlugIns/Widget.appex")
		try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
		defer {
			do { try FileManager.default.removeItem(at: root) } catch { XCTFail("cleanup: \(error)") }
		}
		let info: [String: Any] = ["CFBundleIdentifier": _widget, "CFBundleExecutable": "Widget"]
		try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
			.write(to: widget.appendingPathComponent("Info.plist"))

		let without = NestedBundleAudit.report(appBundle: app, profilePattern: _main, shippedProfile: { _ in nil })
		XCTAssertEqual(without.uncovered.count, 1)

		let with = NestedBundleAudit.report(
			appBundle: app,
			profilePattern: _main,
			additionalPatterns: ["TEAM123456.com.example.app.widget"],
			shippedProfile: { _ in nil }
		)
		XCTAssertTrue(with.uncovered.isEmpty)
	}

	func testTheEngineRequestCarriesNestedProfiles() {
		var request = ZsignEngine.Request(appPath: "/tmp/A.app")
		XCTAssertTrue(request.nestedProvisionPaths.isEmpty)
		request.nestedProvisionPaths = [_widget: "/tmp/widget.mobileprovision"]
		XCTAssertEqual(request.nestedProvisionPaths[_widget], "/tmp/widget.mobileprovision")
	}
}

final class RecoverableFileRemovalTests: XCTestCase {
	private func _scratchFile() throws -> URL {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let file = folder.appendingPathComponent("payload.ipa")
		try Data("payload".utf8).write(to: file)
		return file
	}

	func testARemovedFileComesBackUnchanged() throws {
		let file = try _scratchFile()
		let token = try RecoverableFileRemoval.remove(file)
		XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

		try RecoverableFileRemoval.restore(token)
		XCTAssertEqual(try Data(contentsOf: file), Data("payload".utf8))
		XCTAssertFalse(FileManager.default.fileExists(atPath: token.held.path))
	}

	func testRestoreNeverOverwritesAFileThatTookItsPlace() throws {
		let file = try _scratchFile()
		let token = try RecoverableFileRemoval.remove(file)
		try Data("newer".utf8).write(to: file)

		XCTAssertThrowsError(try RecoverableFileRemoval.restore(token))
		XCTAssertEqual(try Data(contentsOf: file), Data("newer".utf8))
		XCTAssertTrue(FileManager.default.fileExists(atPath: token.held.path), "The held copy must survive a refused restore.")
		RecoverableFileRemoval.discard(token)
	}

	func testDiscardIsPermanentAndRepeatable() throws {
		let file = try _scratchFile()
		let token = try RecoverableFileRemoval.remove(file)
		RecoverableFileRemoval.discard(token)
		RecoverableFileRemoval.discard(token)
		XCTAssertFalse(FileManager.default.fileExists(atPath: token.held.path))
		XCTAssertThrowsError(try RecoverableFileRemoval.restore(token))
	}
}

final class ExtensionProfileCertificateTests: XCTestCase {
	private func _problem(profileCertificates: [Data], leaf: Data?) -> AdditionalProfiles.ImportProblem? {
		AdditionalProfiles.importProblem(
			pattern: "TEAM123456.com.example.app.widget",
			expirationDate: Date().addingTimeInterval(86_400),
			teamIdentifiers: ["TEAM123456"],
			mainTeamIdentifiers: ["TEAM123456"],
			existingPatterns: [],
			profileCertificates: profileCertificates,
			leafCertificate: leaf
		)
	}

	func testAProfileNamingOtherCertificatesIsRefusedAtImport() {
		XCTAssertEqual(_problem(profileCertificates: [Data("other".utf8)], leaf: Data("mine".utf8)), .notIssuedForCertificate)
	}

	func testAProfileNamingThisCertificateIsAccepted() {
		XCTAssertNil(_problem(profileCertificates: [Data("other".utf8), Data("mine".utf8)], leaf: Data("mine".utf8)))
	}

	func testUnknownCertificatesAreLeftToTheSigningTimeCheck() {
		XCTAssertNil(_problem(profileCertificates: [], leaf: Data("mine".utf8)))
		XCTAssertNil(_problem(profileCertificates: [Data("other".utf8)], leaf: nil))
	}
}
