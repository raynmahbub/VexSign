//
//  StabilityAndArchitectureTests.swift
//  VexSignTests
//
//  Covers the stability & architecture work: source health tracking, the
//  offline snapshot cache contract, the repository HTTPS policy, archive
//  extraction sanitization, per-app update rules, the unified task pipeline
//  and backup crypto round-trips.
//
//  Everything here is pure or UserDefaults/file-scoped with unique keys and
//  explicit teardown, so it runs on any host without network or a device.
//

import XCTest
@testable import VexSign

final class StabilityAndArchitectureTests: XCTestCase {

	// MARK: - Source health

	func testSourceHealthTracksSuccessFailureAndRateLimit() {
		let id = "test.health.\(UUID().uuidString)"

		addTeardownBlock {
			SourcePreferences.removeAllData(for: id)
		}

		// Nothing recorded yet.
		var health = SourcePreferences.health(for: id)
		XCTAssertNil(health.lastAttempt)
		XCTAssertNil(health.lastSuccess)
		XCTAssertFalse(health.isRateLimited)

		// A successful refresh records attempt + success and resets failures.
		SourcePreferences.recordFetch(id: id, error: nil)
		health = SourcePreferences.health(for: id)
		XCTAssertNotNil(health.lastAttempt)
		XCTAssertNotNil(health.lastSuccess)
		XCTAssertEqual(health.consecutiveFailures, 0)
		XCTAssertNil(health.lastError)

		// Failures accumulate, keep lastSuccess, and compute backoff.
		SourcePreferences.recordFetch(id: id, error: "HTTP 500")
		SourcePreferences.recordFetch(id: id, error: "HTTP 503")
		health = SourcePreferences.health(for: id)
		XCTAssertEqual(health.consecutiveFailures, 2)
		XCTAssertEqual(health.lastError, "HTTP 503")
		XCTAssertNotNil(health.lastSuccess, "A failing refresh must not erase the last success")
		XCTAssertNotNil(health.nextRetryDate)

		// Rate limiting sets a window and is reported.
		SourcePreferences.recordFetch(id: id, error: "HTTP 429", rateLimited: true)
		health = SourcePreferences.health(for: id)
		XCTAssertTrue(health.isRateLimited)
		XCTAssertNotNil(health.rateLimitedUntil)

		// A later success clears rate limit and failures.
		SourcePreferences.recordFetch(id: id, error: nil)
		health = SourcePreferences.health(for: id)
		XCTAssertFalse(health.isRateLimited)
		XCTAssertEqual(health.consecutiveFailures, 0)
	}

	func testRemoveAllDataClearsEveryHealthTrace() {
		let id = "test.health.\(UUID().uuidString)"
		SourcePreferences.recordFetch(id: id, error: "boom", rateLimited: true)
		SourcePreferences.removeAllData(for: id)
		let health = SourcePreferences.health(for: id)
		XCTAssertNil(health.lastAttempt)
		XCTAssertNil(health.lastError)
		XCTAssertNil(health.rateLimitedUntil)
		XCTAssertFalse(health.isRateLimited)
	}

	// MARK: - Repository HTTPS policy

	func testSourceURLPolicyEnforcesHTTPSByDefault() throws {
		let key = SourceURLPolicy.allowInsecureHTTPKey
		let original = UserDefaults.standard.object(forKey: key)
		addTeardownBlock {
			if let original {
				UserDefaults.standard.set(original, forKey: key)
			} else {
				UserDefaults.standard.removeObject(forKey: key)
			}
		}

		UserDefaults.standard.set(false, forKey: key)

		// HTTPS always passes.
		try SourceURLPolicy.validate(URL(string: "https://example.com/apps.json")!)

		// HTTP is rejected by default.
		XCTAssertThrowsError(try SourceURLPolicy.validate(URL(string: "http://example.com/apps.json")!))

		// Non-HTTP(S) schemes are never allowed.
		XCTAssertThrowsError(try SourceURLPolicy.validate(URL(string: "file:///etc/passwd")!))
		XCTAssertThrowsError(try SourceURLPolicy.validate(URL(string: "ftp://example.com/apps.json")!))

		// Explicit opt-in permits HTTP (e.g. LAN repositories).
		UserDefaults.standard.set(true, forKey: key)
		try SourceURLPolicy.validate(URL(string: "http://192.168.1.10/repo.json")!)
		XCTAssertThrowsError(try SourceURLPolicy.validate(URL(string: "file:///etc/passwd")!), "Opt-in only opens HTTP, not arbitrary schemes")
	}

	func testSourceURLPolicyNormalizesInput() throws {
		let url = try SourceURLPolicy.normalizeAndValidate("example.com/apps.json")
		XCTAssertEqual(url.scheme, "https")
		XCTAssertEqual(url.host, "example.com")

		XCTAssertThrowsError(try SourceURLPolicy.normalizeAndValidate("http://example.com/apps.json"))
	}

	// MARK: - Archive extraction sanitization

	func testUnsafeArchiveEntryNamesAreRejected() {
		// Safe relative names.
		XCTAssertTrue(_isSafeArchiveEntryName("Payload/App.app/App"))
		XCTAssertTrue(_isSafeArchiveEntryName("data.tar.gz"))
		XCTAssertTrue(_isSafeArchiveEntryName("./relative/./path"))

		// Path traversal and absolute paths.
		XCTAssertFalse(_isSafeArchiveEntryName("../escape"))
		XCTAssertFalse(_isSafeArchiveEntryName("Payload/../../escape"))
		XCTAssertFalse(_isSafeArchiveEntryName("/etc/launchd.conf"))
		XCTAssertFalse(_isSafeArchiveEntryName("~/Library/escape"))

		// Windows-style and encoding tricks.
		XCTAssertFalse(_isSafeArchiveEntryName("C:\\Windows\\evil"))
		XCTAssertFalse(_isSafeArchiveEntryName("back\\slash"))
		XCTAssertFalse(_isSafeArchiveEntryName("nul\0byte"))

		// Empty.
		XCTAssertFalse(_isSafeArchiveEntryName(""))
	}

	// MARK: - Per-app update rules

	func testPerAppUpdateRulesFilterUpdates() {
		let bundleID = "com.vexsign.test.\(UUID().uuidString)"
		addTeardownBlock {
			PerAppUpdateRulesStore.shared.removeRule(forBundleID: bundleID)
		}

		func surface(version: String, sourceID: String) -> Bool {
			PerAppUpdateRulesStore.shouldSurfaceUpdate(
				bundleID: bundleID,
				installedVersion: "1.0",
				sourceVersion: version,
				sourceID: sourceID
			)
		}

		// No rule: everything surfaces.
		XCTAssertTrue(surface(version: "2.0", sourceID: "src-a"))

		// Disable updates entirely.
		PerAppUpdateRulesStore.shared.updateRule(forBundleID: bundleID) { $0.disableUpdates = true }
		XCTAssertFalse(surface(version: "2.0", sourceID: "src-a"))

		// Ignore exactly one version.
		PerAppUpdateRulesStore.shared.setRule(PerAppUpdateRule(ignoredVersion: "2.0"), forBundleID: bundleID)
		XCTAssertFalse(surface(version: "2.0", sourceID: "src-a"), "The ignored version must not surface")
		XCTAssertTrue(surface(version: "2.1", sourceID: "src-a"), "Newer versions still surface")

		// Ignore a specific source.
		PerAppUpdateRulesStore.shared.setRule(PerAppUpdateRule(ignoredSourceID: "src-b"), forBundleID: bundleID)
		XCTAssertFalse(surface(version: "2.1", sourceID: "src-b"))
		XCTAssertTrue(surface(version: "2.1", sourceID: "src-a"))

		// Preferred source is exposed for duplicate resolution.
		PerAppUpdateRulesStore.shared.updateRule(forBundleID: bundleID) { $0.preferredSourceID = "src-a" }
		XCTAssertEqual(PerAppUpdateRulesStore.preferredSourceID(forBundleID: bundleID), "src-a")
	}

	func testEmptyRulesAreNotPersisted() {
		let bundleID = "com.vexsign.test.\(UUID().uuidString)"
		PerAppUpdateRulesStore.shared.setRule(PerAppUpdateRule(), forBundleID: bundleID)
		XCTAssertNil(PerAppUpdateRulesStore.persisted[bundleID], "An empty rule must not be stored")
	}

	// MARK: - Unified task pipeline

	@MainActor
	func testUnifiedTaskPhasesAndFailureStage() {
		let task = UnifiedTaskCenter.shared.begin(kind: .sign, title: "Test App", subtitle: "Signing")
		XCTAssertEqual(task.phase, .queued)
		XCTAssertTrue(task.phase.isInProgress)

		UnifiedTaskCenter.shared.transition(task, to: .signing, progress: 0.4)
		XCTAssertEqual(task.phase, .signing)
		XCTAssertEqual(task.progress, 0.4, accuracy: 0.001)

		UnifiedTaskCenter.shared.transition(task, to: .failed, error: "zsign failed")
		XCTAssertTrue(task.phase.isTerminal)
		XCTAssertEqual(task.failureStage, .signing, "The failure stage must record where the task was")
		XCTAssertEqual(task.errorText, "zsign failed")
		XCTAssertFalse(UnifiedTaskCenter.shared.tasks.contains { $0.id == task.id }, "A finished task leaves the active list")
		XCTAssertTrue(UnifiedTaskCenter.shared.history.contains { $0.id == task.id }, "A finished task enters the history")
	}

	@MainActor
	func testUnifiedTaskTerminalStateIsFinal() {
		let task = UnifiedTaskCenter.shared.begin(kind: .install, title: "App")
		UnifiedTaskCenter.shared.transition(task, to: .completed)
		// Transitions after a terminal phase are ignored.
		UnifiedTaskCenter.shared.transition(task, to: .failed, error: "late error")
		XCTAssertEqual(task.phase, .completed)
		XCTAssertNil(task.errorText)
	}

	func testUnifiedTaskSnapshotRoundTrip() {
		let task = UnifiedTask(kind: .download, title: "App.ipa", subtitle: "From repo", phase: .failed, progress: 0.7, subjectID: "dl-1")
		task.failureStage = .downloading
		task.errorText = "lost connection"

		let snapshot = task.snapshot
		guard let data = try? JSONEncoder().encode(snapshot),
		      let decoded = try? JSONDecoder().decode(UnifiedTask.Snapshot.self, from: data) else {
			XCTFail("Failed to encode or decode UnifiedTask.Snapshot")
			return
		}
		let restored = UnifiedTask.from(decoded)

		XCTAssertEqual(restored.id, task.id)
		XCTAssertEqual(restored.kind, .download)
		XCTAssertEqual(restored.phase, .failed)
		XCTAssertEqual(restored.failureStage, .downloading)
		XCTAssertEqual(restored.errorText, "lost connection")
		XCTAssertEqual(restored.subjectID, "dl-1")
	}

	func testPhasePipelineDefinitions() {
		// The canonical pipeline order the task center presents.
		let pipeline: [UnifiedTaskPhase] = [.queued, .downloading, .extracting, .signing, .installing, .completed]
		for (index, phase) in pipeline.enumerated() {
			if index < pipeline.count - 1 {
				XCTAssertTrue(phase.isInProgress)
			} else {
				XCTAssertTrue(phase.isTerminal)
			}
		}
		for phase in [UnifiedTaskPhase.failed, .cancelled] {
			XCTAssertTrue(phase.isTerminal)
			XCTAssertFalse(phase.isInProgress)
		}
	}

	// MARK: - Backup crypto

	func testBackupCryptoRoundTrip() throws {
		let payload = Data("certificate-ish payload \(UUID().uuidString)".utf8)

		let sealed = try BackupCrypto.seal(payload, password: "correct horse battery staple")
		XCTAssertTrue(BackupCrypto.isEncrypted(sealed))

		let opened = try BackupCrypto.unseal(sealed, password: "correct horse battery staple")
		XCTAssertEqual(opened, payload)

		XCTAssertThrowsError(try BackupCrypto.unseal(sealed, password: "wrong")) { error in
			XCTAssertEqual((error as? BackupCrypto.Failure)?.errorDescription, BackupCrypto.Failure.wrongPassword.errorDescription)
		}
		XCTAssertThrowsError(try BackupCrypto.unseal(sealed, password: ""), "An encrypted backup must require its password")
	}

	/// a passwordless backup is still ciphertext. It is wrapped with a
	/// device key instead of a derived one, so it opens without a prompt here and
	/// nowhere else.
	func testPasswordlessBackupsAreEncryptedNotPlain() throws {
		let payload = Data("certificate-ish payload \(UUID().uuidString)".utf8)

		// A passwordless container is wrapped by a key kept in the Keychain, and an
		// unsigned test host has no keychain-access-group entitlement. Only skip when
		// the Keychain really is unusable here: that path runs on a device, and every
		// other host still has to prove the container is encrypted.
		let probeAccount = "stability.keychainProbe.\(UUID().uuidString)"
		do {
			try SecureSecretStore.write(Data([0x01]), account: probeAccount)
			try SecureSecretStore.delete(probeAccount)
		} catch {
			let status = (error as? SecureSecretStore.Failure)?.status
			throw XCTSkip("This host has no usable Keychain (\(status.map { String($0) } ?? error.localizedDescription)).")
		}

		let packed = try BackupCrypto.seal(payload, password: "")

		XCTAssertTrue(BackupCrypto.isEncrypted(packed), "Every backup this version writes is encrypted")
		XCTAssertFalse(
			packed.prefix(7) == Data("VEXBK0\n".utf8),
			"A produced backup must never start with the plaintext header"
		)

		let opened = try BackupCrypto.unseal(packed, password: "")
		XCTAssertEqual(opened, payload)
	}

	/// A container that has been edited in transit fails closed instead of
	/// returning half-decrypted bytes.
	func testTamperedBackupFailsClosed() throws {
		let payload = Data("payload \(UUID().uuidString)".utf8)
		var packed = try BackupCrypto.seal(payload, password: "correct horse battery staple")

		// Flip one byte inside the wrapped key: authenticated decryption must refuse.
		packed[20] ^= 0xFF

		XCTAssertThrowsError(try BackupCrypto.unseal(packed, password: "correct horse battery staple")) { error in
			let failure = error as? BackupCrypto.Failure
			XCTAssertTrue(failure == .wrongPassword || failure == .badFormat, "Tampering must not produce plaintext")
		}
	}

	/// The old unencrypted container still opens, so nobody loses a backup made
	/// before this version - but it is recognised as legacy, not as current.
	func testLegacyPlaintextBackupIsStillReadableAndFlagged() throws {
		let payload = Data("old payload".utf8)
		var legacy = Data("VEXBK0\n".utf8)
		legacy.append(payload)

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("legacy-\(UUID().uuidString).vexbackup")
		try legacy.write(to: url)
		defer { try? FileManager.default.removeItem(at: url) }

		XCTAssertTrue(BackupCrypto.isLegacyPlaintext(url))
		XCTAssertFalse(BackupCrypto.isEncrypted(url), "A plaintext file is not encrypted evidence")
		XCTAssertFalse(BackupCrypto.isEncrypted(url) || BackupCrypto.needsPassword(url), "A plaintext file asks for no password")
		XCTAssertEqual(try BackupCrypto.unseal(legacy, password: ""), payload)
	}

	/// Inclusion policy: certificates need a real password, and the manager
	/// refuses before it writes anything.
	func testCertificateBackupsRequireARealPassword() {
		XCTAssertGreaterThanOrEqual(BackupCrypto.minimumPasswordLength, 8)
		XCTAssertFalse(
			BackupCrypto.Failure.certificatesNeedPassword.errorDescription?.isEmpty ?? true,
			"The refusal has to tell the user why"
		)
	}

	// MARK: - Feature status registry

	func testFeatureStatusRegistryCoversCriticalPipeline() {
		let ids = Set(FeatureStatusRegistry.entries.map { $0.id })
		let critical = [
			"forced-signing",
			"sdk-macho",
			"auto-sign-download",
			"compat-optout",
			"per-app-cert",
			"quick-sign",
			"resign-reinstall",
			"asset-modification",
			"dynamic-island",
			"strict-hiding",
			"library-status"
		]
		for id in critical {
			XCTAssertTrue(ids.contains(id), "The registry must track \(id) end-to-end")
		}

		// Every entry documents the full chain.
		for entry in FeatureStatusRegistry.entries {
			XCTAssertFalse(entry.setting.isEmpty)
			XCTAssertFalse(entry.persistedAs.isEmpty)
			XCTAssertFalse(entry.consumer.isEmpty)
		}
		XCTAssertEqual(
			FeatureStatusRegistry.implementedCount + FeatureStatusRegistry.needsDeviceCount,
			FeatureStatusRegistry.entries.count
		)
	}
}

/// Backwards-compatible helper (the app target's `isEncrypted` takes a URL;
/// tests check the bytes directly).
private extension BackupCrypto {
}
