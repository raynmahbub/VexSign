//
//  StabilityRegressionTests.swift
//  VexSignTests
//
//  Regressions from the consolidated field report on issue #137 (VexSign 1.2.1, iOS 27.2.1).
//
//  The crash: `-[NSManagedObject valueForUndefinedKey:]` during a SwiftUI view update. Build
//  1.2.1 (tag v1.2.1, e930ceb) contained exactly one string-keyed read of a managed object:
//  `RepositoryRow` fell back to `source.value(forKey: "apps")` when a repository's catalogue was
//  not loaded. `AltSource` has never had an `apps` attribute or relationship, so Core Data raised
//  `NSUnknownKeyException` out of the row's body. The read is gone; these tests pin the two facts
//  that made it fatal and the replacement.
//

import CoreData
import CryptoKit
import Foundation
import XCTest
@testable import VexSign

final class StabilityRegressionTests: XCTestCase {
	/// One in-memory store per test, held the way the other storage tests hold theirs.
	private nonisolated(unsafe) static var storage: Storage?

	override func tearDown() {
		Self.storage = nil
		super.tearDown()
	}

	@MainActor
	private func _storage() -> Storage {
		if let storage = Self.storage { return storage }
		let storage = Storage(inMemory: true)
		Self.storage = storage
		return storage
	}

	// MARK: - Core Data crash

	/// The precondition of the crash. If a later model version adds `apps`, this fails and the
	/// row may be given a stored count again — through a typed property, not a string key.
	@MainActor
	func testTheSourceEntityStoresNoAppList() throws {
		let storage = _storage()
		let entity = try XCTUnwrap(
			NSEntityDescription.entity(forEntityName: "AltSource", in: storage.context)
		)
		XCTAssertNil(entity.propertiesByName["apps"], "AltSource has no app list to count")
		XCTAssertEqual(
			Set(entity.propertiesByName.keys),
			["date", "iconURL", "identifier", "name", "sourceURL"],
			"A model change needs a migration and a review of every reader of this entity"
		)
	}

	/// A repository whose catalogue is not loaded has no count, rather than one read from the
	/// stored row. This is the case that crashed: not loaded yet, offline, or failed to refresh.
	func testARepositoryWithoutACatalogueHasNoAppCount() {
		XCTAssertNil(RepositoryRow.appCount(in: nil))
	}

	/// Every string key the storage layer hands to Core Data names a real property. A sort
	/// descriptor or predicate on a missing key raises the same exception as the crash above.
	@MainActor
	func testEveryStringKeyUsedInFetchesIsAModelProperty() throws {
		let storage = _storage()
		let expectations: [(entity: String, keys: [String])] = [
			("Imported", ["sortIndex", "uuid", "date", "identifier"]),
			("Signed", ["sortIndex", "uuid", "date", "identifier"]),
			("CertificatePair", ["date", "uuid"]),
			("AltSource", ["identifier", "date"]),
		]
		for (name, keys) in expectations {
			let entity = try XCTUnwrap(NSEntityDescription.entity(forEntityName: name, in: storage.context))
			for key in keys {
				XCTAssertNotNil(entity.propertiesByName[key], "\(name).\(key) is used as a string key")
			}
		}
	}

	// MARK: - Version comparison (`0.9.9` → `v0.9.9`)

	/// 1.2.1 split on dots and kept the integers: `v0.9.9` became `[9, 9]`, `0.9.9` became
	/// `[0, 9, 9]`, and 9 > 0 made the same version an update of itself.
	func testTheSameVersionWithAndWithoutALeadingVIsNotAnUpdate() {
		for (installed, offered) in [("0.9.9", "v0.9.9"), ("v0.9.9", "0.9.9"), ("0.9.9", "V0.9.9"), ("1.0", "v1.0.0")] {
			XCTAssertFalse(VersionOrder.isNewer(offered, than: installed), "\(installed) → \(offered)")
			XCTAssertFalse(VersionOrder.isNewer(installed, than: offered), "\(offered) → \(installed)")
			XCTAssertEqual(VersionOrder.precedence(installed, offered), .orderedSame)
			XCTAssertTrue(VersionOrder.isSame(installed, offered))
		}
		XCTAssertTrue(VersionOrder.isNewer("v0.9.10", than: "0.9.9"))
		XCTAssertFalse(VersionOrder.isNewer("v0.9.8", than: "0.9.9"))
	}

	func testSameVersionFallsBackToTextOnlyForStringsThatAreNotVersions() {
		XCTAssertTrue(VersionOrder.isSame("Nightly", " nightly "))
		XCTAssertFalse(VersionOrder.isSame("nightly", "1.0"))
		XCTAssertFalse(VersionOrder.isSame("0.9.9", "0.9.10"))
		XCTAssertFalse(VersionOrder.isSame("1.0-beta", "1.0"))
	}

	/// The self-update comparison treated `1.3.0-beta` as `1.3.0.0`, equal to the release.
	func testTheSelfUpdateComparisonUsesTheSharedRule() {
		XCTAssertEqual(SelfUpdateManager.compare("v1.2.1", "1.2.1"), .orderedSame)
		XCTAssertEqual(SelfUpdateManager.compare("1.3.0-beta", "1.3.0"), .orderedAscending)
		XCTAssertEqual(SelfUpdateManager.compare("1.10", "1.9"), .orderedDescending)
		XCTAssertEqual(SelfUpdateManager.compare("1.2", "1.2.0"), .orderedSame)
	}

	// MARK: - Repository refresh notice

	func testTheRefreshNoticeNamesTheRepositories() {
		let one = RepositoryRefreshNotice.message(naming: ["Alpha"])
		XCTAssertTrue(one.contains("Alpha"))

		let three = RepositoryRefreshNotice.message(naming: ["Alpha", "Beta", "Gamma"])
		XCTAssertTrue(three.contains("Alpha"))
		XCTAssertTrue(three.contains("Beta"))
		XCTAssertFalse(three.contains("Gamma"), "Only the first names are spelled out; the rest are counted")
		XCTAssertTrue(three.contains("1"))
	}

	func testTheRefreshNoticeIgnoresBlankNames() {
		let unnamed = RepositoryRefreshNotice.message(naming: ["", "  "])
		XCTAssertEqual(unnamed, RepositoryRefreshNotice.message(naming: []))
		XCTAssertFalse(unnamed.contains("%"), "No unfilled format placeholder may reach the banner")
	}

	// MARK: - Entitlement editor

	/// Adding a preset must not replace a value the user already set (the App Groups preset
	/// carries a placeholder group).
	func testAPresetDoesNotReplaceAnExistingValue() {
		let key = "com.apple.security.application-groups"
		let existing: [String: Any] = [key: ["group.com.example.mine"], "get-task-allow": true]
		let merged = EntitlementsPreset.appGroups.merging(into: existing)
		XCTAssertEqual(merged[key] as? [String], ["group.com.example.mine"])
		XCTAssertEqual(merged["get-task-allow"] as? Bool, true)

		let added = EntitlementsPreset.siri.merging(into: existing)
		XCTAssertEqual(added["com.apple.developer.siri"] as? Bool, true)
		XCTAssertEqual(added.count, existing.count + 1)
	}

	/// A JSON `null` has no property-list type; a dictionary carrying one cannot be saved.
	func testOnlyPropertyListValuesAreStorable() {
		XCTAssertTrue(EntitlementsManager.isStorable(["a": true, "b": ["x", "y"], "c": ["k": 1]]))
		XCTAssertFalse(EntitlementsManager.isStorable(["a": NSNull()]))
		XCTAssertFalse(EntitlementsManager.isStorable(["a": ["nested": NSNull()]]))
	}

	func testAJSONExportWithNullIsNotImported() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("StabilityRegressionTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let invalid = directory.appendingPathComponent("null.json")
		try Data(#"{"aps-environment": null}"#.utf8).write(to: invalid)
		XCTAssertNil(EntitlementsManager.parseEntitlements(from: invalid))

		let valid = directory.appendingPathComponent("valid.json")
		try Data(#"{"aps-environment": "development", "get-task-allow": true}"#.utf8).write(to: valid)
		let parsed = try XCTUnwrap(EntitlementsManager.parseEntitlements(from: valid))
		XCTAssertEqual(parsed["aps-environment"] as? String, "development")
		XCTAssertEqual(parsed["get-task-allow"] as? Bool, true)
	}

	/// Types survive the write the signer reads back: a Boolean stays a Boolean, an array of
	/// strings keeps its order, a nested dictionary keeps its keys.
	func testEntitlementsRoundTripThroughTheWrittenFile() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("StabilityRegressionTests-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("entitlements.plist")

		let original: [String: Any] = [
			"get-task-allow": false,
			"application-identifier": "TEAMID1234.com.example.app",
			"keychain-access-groups": ["TEAMID1234.b", "TEAMID1234.a"],
			"com.apple.developer.icloud-container-environment": ["nested": ["Production"]],
			"com.example.count": 3,
		]
		try EntitlementBuilder.write(original, to: url)
		let restored = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])

		XCTAssertEqual(restored.count, original.count)
		let flag = try XCTUnwrap(restored["get-task-allow"] as? NSNumber)
		XCTAssertTrue(CFGetTypeID(flag) == CFBooleanGetTypeID(), "false must not come back as the integer 0")
		XCTAssertEqual(flag.boolValue, false)
		XCTAssertEqual(restored["application-identifier"] as? String, "TEAMID1234.com.example.app")
		XCTAssertEqual(restored["keychain-access-groups"] as? [String], ["TEAMID1234.b", "TEAMID1234.a"])
		XCTAssertEqual(
			(restored["com.apple.developer.icloud-container-environment"] as? [String: [String]])?["nested"],
			["Production"]
		)
		XCTAssertEqual(restored["com.example.count"] as? Int, 3)
	}

	// MARK: - Large-file hashing

	/// The streamed digest must be unchanged by draining a pool per chunk, including across a
	/// chunk boundary (the read size is 1 MiB).
	func testStreamedDigestMatchesAOneShotDigestAcrossChunks() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("StabilityRegressionTests-\(UUID().uuidString).bin")
		defer { try? FileManager.default.removeItem(at: url) }
		var bytes = Data(count: (1 << 20) * 2 + 4_097)
		for index in stride(from: 0, to: bytes.count, by: 4_093) { bytes[index] = UInt8(truncatingIfNeeded: index) }
		try bytes.write(to: url)

		let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
		XCTAssertEqual(FileIntegrity.sha256(of: url), expected)
		XCTAssertEqual(try BackupVerification.digest(of: url), expected)
		XCTAssertNil(FileIntegrity.sha256(of: url.appendingPathExtension("missing")))
	}
}
