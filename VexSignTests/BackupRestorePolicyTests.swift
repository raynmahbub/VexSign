//
//  BackupRestorePolicyTests.swift
//  VexSignTests
//
//  The rules a restore applies before it writes anything, and the rules a backup applies to what
//  it may carry.
//
//  Both existed as inline `if … continue` chains inside `BackupManager.restore` and a prefix test
//  inside `makeBackup`, where nothing could assert them: the full path needs a decrypted container,
//  the real app container and Core Data. These are the parts that are decided from booleans.
//
//  The settings policy is the one with a lasting consequence: a backup is a file the user keeps,
//  copies and may restore on another install. Anything credential-shaped must never be inside one,
//  and must never be written back into `UserDefaults` by a restore.
//

import Foundation
import NimbleExtensions
import XCTest
@testable import VexSign

final class BackupRestorePolicyTests: XCTestCase {
	// MARK: - What a restore may write

	func testAnEntryIsRestoredOnlyWhenNothingIsInTheWay() {
		XCTAssertEqual(
			BackupRestorePlan.decision(alreadyTracked: false, payloadPresent: true, destinationOccupied: false),
			.restore
		)
		XCTAssertTrue(
			BackupRestorePlan.decision(alreadyTracked: false, payloadPresent: true, destinationOccupied: false)
				.shouldRestore
		)
	}

	func testAnAlreadyTrackedItemIsNeverReplaced() {
		// Whatever else is true about the entry, the user's existing copy wins.
		XCTAssertEqual(
			BackupRestorePlan.decision(alreadyTracked: true, payloadPresent: true, destinationOccupied: true),
			.skipAlreadyPresent
		)
		XCTAssertEqual(
			BackupRestorePlan.decision(alreadyTracked: true, payloadPresent: false, destinationOccupied: true),
			.skipAlreadyPresent
		)
		XCTAssertFalse(
			BackupRestorePlan.decision(alreadyTracked: true, payloadPresent: true, destinationOccupied: false)
				.shouldRestore
		)
	}

	func testAMissingPayloadIsSkippedRatherThanFatal() {
		// One damaged entry must not abort the entries after it.
		XCTAssertEqual(
			BackupRestorePlan.decision(alreadyTracked: false, payloadPresent: false, destinationOccupied: true),
			.skipMissingPayload
		)
		XCTAssertEqual(
			BackupRestorePlan.decision(alreadyTracked: false, payloadPresent: false, destinationOccupied: false),
			.skipMissingPayload
		)
	}

	func testAnUntrackedDirectoryIsNeverReplaced() {
		// What an interrupted earlier import leaves behind: files with no record pointing at them.
		XCTAssertEqual(
			BackupRestorePlan.decision(alreadyTracked: false, payloadPresent: true, destinationOccupied: true),
			.skipDestinationOccupied
		)
	}

	func testEveryCombinationOfTheRuleIsDecided() {
		// No input may fall through: a restore that guesses is a restore that overwrites.
		for tracked in [true, false] {
			for payload in [true, false] {
				for occupied in [true, false] {
					let decision = BackupRestorePlan.decision(
						alreadyTracked: tracked, payloadPresent: payload, destinationOccupied: occupied
					)
					let expected: BackupRestorePlan.Decision = tracked
						? .skipAlreadyPresent
						: (!payload ? .skipMissingPayload : (occupied ? .skipDestinationOccupied : .restore))
					XCTAssertEqual(decision, expected)
					XCTAssertEqual(decision.shouldRestore, !tracked && payload && !occupied)
				}
			}
		}
	}

	func testRestoringTheSameArchiveTwiceAddsNothingTheSecondTime() {
		// The idempotency the rule buys: after a pass, everything it wrote is tracked.
		let entries = ["cert-a", "cert-b", "cert-c"]
		var tracked = Set<String>()
		var firstPass: [String] = []
		for entry in entries where BackupRestorePlan.decision(
			alreadyTracked: tracked.contains(entry), payloadPresent: true, destinationOccupied: false
		).shouldRestore {
			firstPass.append(entry)
			tracked.insert(entry)
		}
		XCTAssertEqual(firstPass, entries)

		let secondPass = entries.filter { entry in
			BackupRestorePlan.decision(
				alreadyTracked: tracked.contains(entry), payloadPresent: true, destinationOccupied: false
			).shouldRestore
		}
		XCTAssertTrue(secondPass.isEmpty, "a re-restore must skip, not duplicate")
	}

	// MARK: - What a backup may carry

	@MainActor
	func testOrdinarySettingsAreBackedUp() {
		for key in [
			"VexSign.installationMethod",
			"VexSign.serverMethod",
			"VexSign.appearance.theme",
			"vexsign.selectedTab",
			"signing_options.compatibility"
		] {
			XCTAssertTrue(BackupManager.isBackupableSettingKey(key), key)
		}
	}

	@MainActor
	func testDeviceSpecificAndDerivedKeysAreExcluded() {
		for key in [
			"vexsign.selectedCert",              // restored by uuid remap instead
			"VexSign.premiumSourceHosts",       // install-bound activation
			"VexSign.defaultImportFolderName",
			"VexSign.defaultImportFolderBookmark", // security-scoped, dead elsewhere
			"VexSign.downloadBubblePositionX",
			"VexSign.downloadBubblePositionY",
			"VexSign.certHash.ABCDEF"           // derived from the stored bundle
		] {
			XCTAssertFalse(BackupManager.isBackupableSettingKey(key), key)
		}
	}

	@MainActor
	func testCredentialNamespacesAreNeverBackedUp() {
		// `IdentityVault` mirrors migrated identity values into preferences; a backup must not
		// carry another install's identity, and a restore must not write one back.
		for key in [
			"VexSign.vault.premiumAPIKey",
			"VexSign.vault.premiumActive",
			"VexSign.vault.premiumURLs",
			"VexSign.vault.deviceUUID",
			"vexsign.vault.premiumAPIKey"
		] {
			XCTAssertTrue(BackupManager.isCredentialSettingKey(key), key)
			XCTAssertFalse(BackupManager.isBackupableSettingKey(key), key)
		}
	}

	@MainActor
	func testTheLegacyCloudTokenIsNeverBackedUp() {
		// Written in plaintext by earlier builds, and still present on installs whose Keychain
		// migration failed. It must never leave in a backup or come back through a restore.
		XCTAssertFalse(BackupManager.isBackupableSettingKey("VexSign.cloudSigningKey"))
		XCTAssertFalse(BackupManager.isBackupableSettingKey("vexsign.cloudSigningKey"),
					   "both accepted prefixes have to be denied, because the deny list is exact")
	}

	@MainActor
	func testCredentialShapedNamesAreExcluded() {
		for key in [
			"VexSign.someService.apiKey",
			"VexSign.someService.APIKEY",
			"VexSign.publisher.token",
			"VexSign.publisher.Token",
			"VexSign.service.secret",
			"VexSign.service.password",
			"VexSign.service.passphrase"
		] {
			XCTAssertTrue(BackupManager.isCredentialSettingKey(key), key)
			XCTAssertFalse(BackupManager.isBackupableSettingKey(key), key)
		}
	}

	@MainActor
	func testAKeyThatMerelyMentionsACredentialIsStillBackedUp() {
		// The rule must not swallow ordinary preferences: these are settings, not secrets.
		for key in [
			"VexSign.keyboardShortcutsEnabled",
			"VexSign.keychainNoticeShown",
			"VexSign.showPasswordFieldHint",
			"VexSign.publisher.apiKeyHelpSeen"
		] {
			XCTAssertFalse(BackupManager.isCredentialSettingKey(key), key)
			XCTAssertTrue(BackupManager.isBackupableSettingKey(key), key)
		}
	}

	@MainActor
	func testKeysOutsideTheAppNamespacesAreIgnored() {
		for key in ["AppleLanguages", "NSNavLastRootDirectory", "com.apple.springboard.foo", "SBShowNonDefaultSystemApps"] {
			XCTAssertFalse(BackupManager.isBackupableSettingKey(key), key)
		}
	}

	// MARK: - What the restore reports

	func testTheSummaryListsOnlyRestoredComponentsInTheDocumentedOrder() {
		var summary = BackupRestoreSummary()
		summary.record(.library, added: 2, skipped: 1)
		summary.record(.certificates, added: 3, skipped: 0)
		let lines = summary.lines

		XCTAssertEqual(lines.count, 2, "a component the restore did not touch must not be listed")
		XCTAssertEqual(
			lines[0],
			String.localized("%@: %lld added", arguments: BackupComponents.certificates.title, 3)
		)
		XCTAssertEqual(
			lines[1],
			String.localized("%@: %lld added, %lld skipped", arguments: BackupComponents.library.title, 2, 1)
		)
		XCTAssertTrue(summary.restored.contains(.library))
		XCTAssertFalse(summary.restored.contains(.tweaks))
	}
}
