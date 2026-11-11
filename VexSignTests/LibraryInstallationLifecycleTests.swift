//
//  LibraryInstallationLifecycleTests.swift
//  VexSignTests
//
//  Regression tests for a signed app reading "Not installed" while iOS was installing it.
//
//  The root cause was a missing state, not a wrong reading: `InstalledState` could only say
//  installed / other version / not installed / unknown, so there was nothing to publish while an
//  attempt was in flight. Every read that landed in that window published whatever the device
//  happened to answer mid-install — and the window is exactly when the app returns to the
//  foreground from iOS's install prompt, which forces a refresh of every visible row.
//
//  These tests drive `LibraryStatusStore` through the whole lifecycle with stubbed device
//  evidence: no probe, no installer, no device.
//

import Foundation
import NimbleExtensions
import XCTest
import os
@testable import VexSign

final class LibraryInstallationLifecycleTests: XCTestCase {
	private let identifier = "com.example.aidoku"

	// MARK: - Before any attempt

	@MainActor
	func testARowIsUnknownBeforeAnAttemptAndNeverGuessesInstalled() async throws {
		let store = _store(answers: [:])
		store.request(_request("row"))
		try await _waitUntil { store.statuses["row"]?.isKnown == true }

		XCTAssertEqual(store.statuses["row"]?.installed, .unknown)
		XCTAssertNil(store.activeInstallation(identifier: identifier))
		XCTAssertFalse(store.isInstalling(identifier))
		// A read that could not answer says "Unknown", never a guess either way.
		let badge = InstalledBadge(try XCTUnwrap(store.statuses["row"]))
		XCTAssertEqual(badge.title, String.localized("Unknown"))
		XCTAssertEqual(badge.tone, .neutral)
	}

	@MainActor
	func testANegativeReadingBeforeAnAttemptIsStillNotInstalled() async throws {
		// The distinction the fix has to preserve: "Not installed" is a real answer when nothing
		// is being attempted. Only an in-flight attempt may override it.
		let store = _store(answers: [identifier: InstalledApp(bundleIdentifier: identifier, isInstalled: false)])
		store.request(_request("row"))
		try await _waitUntil { store.statuses["row"]?.isKnown == true }
		XCTAssertEqual(store.statuses["row"]?.installed, .notInstalled)
	}

	// MARK: - While the attempt is in flight

	@MainActor
	func testARegisteredAttemptPublishesInstallingToEveryRowWithThatIdentifier() async throws {
		let store = _store(answers: [:])
		// Two library entries, one bundle identifier: a signed copy and the import it came from.
		store.request(_request("signed", expectedVersion: "0.9", isSigned: true))
		store.request(_request("imported", expectedVersion: "0.8", isSigned: false))
		try await _waitUntil { store.statuses["signed"]?.isKnown == true && store.statuses["imported"]?.isKnown == true }

		let attempt = try XCTUnwrap(store.beginInstallation(identifier: identifier, attemptID: "attempt-1", taskID: "task-1"))
		XCTAssertEqual(attempt.identifier, identifier)
		XCTAssertEqual(attempt.attemptID, "attempt-1")
		XCTAssertEqual(attempt.taskID, "task-1")

		XCTAssertEqual(store.statuses["signed"]?.installed, .installing)
		XCTAssertEqual(store.statuses["imported"]?.installed, .installing)
		XCTAssertTrue(store.isInstalling(identifier))
	}

    @MainActor
    func testLibraryBadgeProjectsOnlyTheOwningTaskPhase() {
        let store = _store(answers: [:])
        store.request(_request("row"))
        store.beginInstallation(identifier: identifier, attemptID: "one", taskID: "task",
                                initialPhase: .preparingInstallation)
        XCTAssertEqual(store.statuses["row"]?.installationTitle, String.localized("Preparing installation"))
        store.updateInstallationPhase(identifier: identifier, attemptID: "one", phase: .waitingForIOS)
        let status = store.statuses["row"]!
        XCTAssertEqual(status.installed, .installing)
        XCTAssertEqual(status.installationTitle, String.localized("Waiting for iOS confirmation"))
        XCTAssertEqual(InstalledBadge(status).title, String.localized("Waiting for iOS confirmation"))
        store.updateInstallationPhase(identifier: identifier, attemptID: "old", phase: .verifying)
        XCTAssertEqual(store.statuses["row"]?.installationTaskPhase, .waitingForIOS)
        store.updateInstallationPhase(identifier: identifier, attemptID: "one", phase: .verifying)
        XCTAssertEqual(store.statuses["row"]?.installationTitle, String.localized("Verifying installation"))
        store.endInstallation(identifier: identifier, attemptID: "one")
        XCTAssertNil(store.statuses["row"]?.installationTaskPhase)
    }

	func testInstallingIsItsOwnStateAndNotAVerdictEitherWay() {
		XCTAssertEqual(InstalledState.installing.title, String.localized("Installing"))
		XCTAssertNotEqual(InstalledState.installing, .installed)
		XCTAssertNotEqual(InstalledState.installing, .notInstalled)
		XCTAssertNotEqual(InstalledState.installing, .unknown)
		XCTAssertTrue(InstalledState.installing.isTransient)
		XCTAssertFalse(InstalledState.installed.isTransient)
		XCTAssertFalse(InstalledState.notInstalled.isTransient)
		XCTAssertFalse(InstalledState.unknown.isTransient)

		let badge = InstalledBadge(.installing)
		XCTAssertEqual(badge?.title, String.localized("Installing"))
		XCTAssertEqual(badge?.tone, .active)
		XCTAssertEqual(badge?.systemImage, "arrow.triangle.2.circlepath")
		// A transient state is still a badge: saying nothing is what let a stale negative stand.
		XCTAssertNotNil(badge)
	}

	func testTheDeviceProbeNeverDerivesTheTransientStateItself() {
		// `Installing` is a lifecycle state owned by the queue, not a device reading. If `derive`
		// could produce it, a probe result would be able to claim an install that was never
		// requested.
		XCTAssertNotEqual(InstalledState.derive(from: nil, expecting: "1.0"), .installing)
		XCTAssertNotEqual(
			InstalledState.derive(from: InstalledApp(bundleIdentifier: identifier, isInstalled: false), expecting: "1.0"),
			.installing
		)
		XCTAssertNotEqual(
			InstalledState.derive(from: InstalledApp(bundleIdentifier: identifier, isInstalled: true, version: "1.0"), expecting: "1.0"),
			.installing
		)
		XCTAssertNotEqual(
			InstalledState.derive(from: InstalledApp(bundleIdentifier: identifier, isInstalled: false, isPlaceholder: true), expecting: "1.0"),
			.installing
		)
	}

	@MainActor
	func testAProbeReadingCannotOverwriteAnActiveAttempt() async throws {
		// Mid-install, LaunchServices answers "not there yet". That is not a verdict.
		let store = _store(answers: [identifier: InstalledApp(bundleIdentifier: identifier, isInstalled: false)])
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		store.request(_request("row"))

		try await Task.sleep(nanoseconds: 250_000_000)
		XCTAssertEqual(store.statuses["row"]?.installed, .installing,
			"A device read taken while iOS is writing the bundle must not become the badge")
	}

	@MainActor
	func testAForcedRefreshAndAReturnFromTheIOSPromptCannotReadThroughAnAttempt() async throws {
		// `refreshKnown()` runs on every scene-phase change to active — which is precisely when
		// the user comes back from accepting iOS's install prompt.
		let probe = _GatedProbe(answer: InstalledApp(bundleIdentifier: identifier, isInstalled: false))
		defer { probe.releaseAll() }
		let store = _store(probe: probe)
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")

		store.request(_request("row"), force: true)
		store.refreshKnown()
		store.invalidate(bundleIdentifier: identifier)
		try await Task.sleep(nanoseconds: 250_000_000)

		XCTAssertEqual(probe.started, 0, "No device read is dispatched while an attempt owns the answer")
		XCTAssertEqual(store.statuses["row"]?.installed, .installing)
	}

	@MainActor
	func testAReadAlreadyInFlightWhenTheAttemptStartedCannotPublishItsNegative() async throws {
		let probe = _GatedProbe(answer: InstalledApp(bundleIdentifier: identifier, isInstalled: false))
		defer { probe.releaseAll() }
		let store = _store(probe: probe)
		store.request(_request("row"))
		try await _waitUntil { probe.started == 1 }

		// The install starts while that read is still blocked inside a private lookup.
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		XCTAssertEqual(store.statuses["row"]?.installed, .installing)

		probe.releaseAll()
		try await _waitUntil { probe.returned == 1 }
		try await Task.sleep(nanoseconds: 250_000_000)
		XCTAssertEqual(store.statuses["row"]?.installed, .installing)
	}

	// MARK: - Confirmed

	@MainActor
	func testAConfirmedInstallBecomesInstalledWhenTheAttemptEnds() async throws {
		let store = _store(answers: [identifier: InstalledApp(bundleIdentifier: identifier, isInstalled: false)])
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		store.request(_request("row"))
		XCTAssertEqual(store.statuses["row"]?.installed, .installing)

		// What `AppInstaller` does once the device proves the install, before the queue ends it.
		store.recordConfirmedInstallation(bundleIdentifier: identifier, version: "0.9")
		XCTAssertEqual(store.statuses["row"]?.installed, .installing,
			"Confirmation is recorded while monitoring continues; it is published when the attempt ends")

		XCTAssertTrue(store.endInstallation(identifier: identifier, attemptID: "attempt-1"))
		XCTAssertEqual(store.statuses["row"]?.installed, .installed)
		XCTAssertNil(store.activeInstallation(identifier: identifier))
		XCTAssertFalse(store.isInstalling(identifier))
	}

	@MainActor
	func testAConfirmedInstallAtADifferentVersionSaysSo() async throws {
		let store = _store(answers: [:])
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		store.request(_request("row", expectedVersion: "0.9"))

		store.recordConfirmedInstallation(bundleIdentifier: identifier, version: "0.8")
		store.endInstallation(identifier: identifier, attemptID: "attempt-1")

		XCTAssertEqual(store.statuses["row"]?.installed, .installedOtherVersion("0.8"))
	}

	// MARK: - Unconfirmed, failed, cancelled

	@MainActor
	func testAnUnconfirmedAttemptEndsUnknownInsteadOfBecomingAFalseNegative() async throws {
		// iOS never exposed enough evidence. No confirmation is recorded, and the honest result is
		// "Unknown" — not "Not installed", and not "Installed".
		let store = _store(answers: [:])
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		store.request(_request("row"))
		XCTAssertEqual(store.statuses["row"]?.installed, .installing)

		XCTAssertTrue(store.endInstallation(identifier: identifier, attemptID: "attempt-1"))
		try await _waitUntil { store.statuses["row"] != nil }
		XCTAssertEqual(store.statuses["row"]?.installed, .unknown)
		XCTAssertNotEqual(store.statuses["row"]?.installed, .notInstalled)
		XCTAssertNotEqual(store.statuses["row"]?.installed, .installed)
	}

	@MainActor
	func testAFailedAttemptClearsTheTransientState() async throws {
		let store = _store(answers: [identifier: InstalledApp(bundleIdentifier: identifier, isInstalled: false)])
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		store.request(_request("row"))

		// A failure records no confirmation, so ending the attempt returns the row to the device's
		// own answer rather than leaving it stuck on "Installing".
		XCTAssertTrue(store.endInstallation(identifier: identifier, attemptID: "attempt-1"))
		XCTAssertNil(store.activeInstallation(identifier: identifier))
		try await _waitUntil { store.statuses["row"]?.installed != .installing }
		XCTAssertNotEqual(store.statuses["row"]?.installed, .installing)
	}

	@MainActor
	func testACancelledAttemptClearsTheTransientState() async throws {
		let store = _store(answers: [:])
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		store.request(_request("row"))

		XCTAssertTrue(store.endInstallation(identifier: identifier, attemptID: "attempt-1"))
		XCTAssertFalse(store.isInstalling(identifier))
		XCTAssertNotEqual(store.statuses["row"]?.installed, .installing)
	}

	@MainActor
	func testEndingTheSameAttemptTwiceIsInert() async throws {
		let store = _store(answers: [:])
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		XCTAssertTrue(store.endInstallation(identifier: identifier, attemptID: "attempt-1"))
		XCTAssertFalse(store.endInstallation(identifier: identifier, attemptID: "attempt-1"))
	}

	@MainActor
	func testAQueueResetForgetsEveryAttempt() async throws {
		let store = _store(answers: [:])
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		store.beginInstallation(identifier: "com.example.other", attemptID: "attempt-2")
		store.resetInstallations()

		XCTAssertNil(store.activeInstallation(identifier: identifier))
		XCTAssertNil(store.activeInstallation(identifier: "com.example.other"))
		XCTAssertFalse(store.isInstalling(identifier))
	}

	@MainActor
	func testAnAttemptWithoutAnIdentifierIsNotRegistered() {
		let store = _store(answers: [:])
		XCTAssertNil(store.beginInstallation(identifier: "", attemptID: "attempt-1"))
		XCTAssertNil(store.beginInstallation(identifier: identifier, attemptID: ""))
		XCTAssertFalse(store.isInstalling(nil))
		XCTAssertFalse(store.isInstalling(""))
	}

	// MARK: - Stale attempts

	@MainActor
	func testAStaleAttemptCanNeitherClearNorRewriteANewerOne() async throws {
		let store = _store(answers: [:])
		store.request(_request("row"))
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		// A retry replaces the attempt rather than racing it.
		store.beginInstallation(identifier: identifier, attemptID: "attempt-2")
		XCTAssertEqual(store.activeInstallation(identifier: identifier)?.attemptID, "attempt-2")

		// The abandoned first attempt finally reports in.
		XCTAssertFalse(store.endInstallation(identifier: identifier, attemptID: "attempt-1"))
		XCTAssertEqual(store.statuses["row"]?.installed, .installing)
		XCTAssertEqual(store.activeInstallation(identifier: identifier)?.attemptID, "attempt-2")

		// Even a confirmation carried by the stale attempt stays unpublished until the live one ends.
		store.recordConfirmedInstallation(bundleIdentifier: identifier, version: "0.9")
		XCTAssertEqual(store.statuses["row"]?.installed, .installing)

		XCTAssertTrue(store.endInstallation(identifier: identifier, attemptID: "attempt-2"))
		XCTAssertEqual(store.statuses["row"]?.installed, .installed)
	}

	@MainActor
	func testAnAttemptForOneIdentifierDoesNotLeakToAnother() async throws {
		let store = _store(answers: [:])
		store.request(_request("row"))
		store.request(LibraryStatusStore.Request(uuid: "other", bundleIdentifier: "com.example.other",
			expectedVersion: "1.0", bundleURL: nil, isSigned: true))
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")

		XCTAssertEqual(store.statuses["row"]?.installed, .installing)
		XCTAssertNotEqual(store.statuses["other"]?.installed, .installing)
		XCTAssertFalse(store.isInstalling("com.example.other"))
	}

	// MARK: - Rows mounted later

	@MainActor
	func testARowMountedDuringAnAttemptReadsInstallingImmediately() {
		let store = _store(answers: [:])
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1")
		// A row scrolled into view after the install started has no cached reading at all.
		store.request(_request("late"))
		XCTAssertEqual(store.statuses["late"]?.installed, .installing)
	}

	@MainActor
	func testAnExpiredAttemptStopsPinningTheRow() async throws {
		let store = _store(answers: [:])
		store.request(_request("row"))
		try await _waitUntil { store.statuses["row"]?.isKnown == true }

		// Registered with a start date already past the backstop: what an attempt looks like when
		// whatever owned it died without ever ending it.
		let abandoned = Date().addingTimeInterval(-(LibraryStatusStore.attemptTimeout + 60))
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1", now: abandoned)
		XCTAssertEqual(store.statuses["row"]?.installed, .installing, "Registering publishes immediately")

		XCTAssertNil(store.activeInstallation(identifier: identifier))
		XCTAssertFalse(store.isInstalling(identifier))
		store.request(_request("row"), force: true)
		try await _waitUntil { store.statuses["row"]?.installed != .installing }
		XCTAssertEqual(store.statuses["row"]?.installed, .unknown,
			"A transient state must not outlive the attempt that published it")
	}

	@MainActor
	func testAnAttemptIsBelievedForExactlyItsBound() {
		let store = _store(answers: [:])
		let start = Date(timeIntervalSince1970: 2_000_000)
		store.beginInstallation(identifier: identifier, attemptID: "attempt-1", now: start)

		// Both accessors are asked about the same synthetic instant, which is the property under
		// test: they must agree. Anchoring the attempt at epoch 2,000,000 and then asking
		// `isInstalling` without a clock compared a deliberate fixture against the real clock, so
		// the attempt was decades stale and the two disagreed.
		let atBound = start.addingTimeInterval(LibraryStatusStore.attemptTimeout)
		// Inclusive: an attempt that started exactly `attemptTimeout` ago is still the row's
		// authoritative answer, so the backstop cannot expire a live attempt early.
		XCTAssertNotNil(store.activeInstallation(identifier: identifier, now: atBound))
		XCTAssertTrue(store.isInstalling(identifier, now: atBound))

		// One tick past it, the owner is presumed dead and the row stops claiming "Installing".
		let pastBound = start.addingTimeInterval(LibraryStatusStore.attemptTimeout + 1)
		XCTAssertNil(store.activeInstallation(identifier: identifier, now: pastBound))
		XCTAssertFalse(store.isInstalling(identifier, now: pastBound))
	}

	// MARK: - Helpers

	private func _request(_ uuid: String, expectedVersion: String? = "0.9", isSigned: Bool = true) -> LibraryStatusStore.Request {
		LibraryStatusStore.Request(uuid: uuid, bundleIdentifier: identifier,
			expectedVersion: expectedVersion, bundleURL: nil, isSigned: isSigned)
	}

	@MainActor
	private func _store(answers: [String: InstalledApp?]) -> LibraryStatusStore {
		_store(probe: _AnswerProbe(answers: answers))
	}

	@MainActor
	private func _store(probe: InstalledAppProbing) -> LibraryStatusStore {
		LibraryStatusStore(
			probe: probe,
			readGuest: { _ in .unavailable },
			readSignature: { _ in .noCodeSignature }
		)
	}

	@MainActor
	private func _waitUntil(_ condition: () -> Bool) async throws {
		for _ in 0..<500 {
			if condition() { return }
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		XCTFail("Timed out waiting for the library status to settle")
		throw NSError(domain: "LibraryInstallationLifecycleTests", code: 1)
	}
}

// MARK: - Stubs

/// One fixed answer per identifier. `nil` is "the device could not answer", which is what a
/// filtered LaunchServices lookup returns and what must never become a verdict.
private struct _AnswerProbe: InstalledAppProbing {
	let answers: [String: InstalledApp?]

	func installedApp(for bundleIdentifier: String) -> InstalledApp? {
		answers[bundleIdentifier] ?? nil
	}
}

/// Releases each read individually, so a device answer can be made to arrive after an
/// installation attempt has started — the race that produced the false "Not installed".
private final class _GatedProbe: InstalledAppProbing {
	private let state = OSAllocatedUnfairLock(initialState: (started: 0, returned: 0))
	private let gate = DispatchSemaphore(value: 0)
	private let answer: InstalledApp?

	init(answer: InstalledApp?) { self.answer = answer }

	var started: Int { state.withLock { $0.started } }
	var returned: Int { state.withLock { $0.returned } }

	func installedApp(for bundleIdentifier: String) -> InstalledApp? {
		state.withLock { $0.started += 1 }
		_ = gate.wait(timeout: .now() + 10)
		defer { state.withLock { $0.returned += 1 } }
		return answer
	}

	func releaseAll() {
		let waiting = max(started - returned, 0) + 4
		for _ in 0..<waiting { gate.signal() }
	}
}
