//
//  InstallConfirmationTests.swift
//  VexSignTests
//
//  Covers the install verdict (docs/ROADMAP.md, audit ): an install is reported as
//  successful only when the device says the app is there at the version that was sent, and every
//  other ending has its own answer — cancelled, rolled back, or timed out.
//
//  The engine is pure, so every transition and deadline is tested with explicit dates. Two
//  end-to-end cases drive `InstallWatcher` with a scripted progress counter and a fixed probe.
//

import Foundation
import XCTest
@testable import VexSign

final class InstallConfirmationTests: XCTestCase {
	private let bundleID = "com.example.app"
	private let epoch = Date(timeIntervalSince1970: 1_000_000)

	private func at(_ seconds: TimeInterval) -> Date {
		epoch.addingTimeInterval(seconds)
	}

	private func confirmation(
		version: String? = "1.2.0",
		limits: InstallConfirmation.Limits = InstallConfirmation.Limits()
	) -> InstallConfirmation {
		InstallConfirmation(
			expectation: .init(bundleIdentifier: bundleID, version: version),
			limits: limits
		)
	}

	private func app(version: String? = "1.2.0", placeholder: Bool = false) -> InstalledApp {
		InstalledApp(
			bundleIdentifier: bundleID,
			isInstalled: true,
			isPlaceholder: placeholder,
			version: version
		)
	}

	private var missing: InstalledApp {
		InstalledApp(bundleIdentifier: bundleID, isInstalled: false)
	}

	/// Puts the engine in `.verifying`: downloading, then progress ends.
	private func verifying(_ confirmation: inout InstallConfirmation, endedAt time: TimeInterval = 10) {
		_ = confirmation.record(progress: 0.4, at: at(0))
		XCTAssertEqual(confirmation.record(progress: 0, at: at(time)), .verifying)
	}

	// MARK: - Start

	func testNothingHappensUntilTheStartDeadline() {
		var confirmation = confirmation()

		XCTAssertEqual(confirmation.record(progress: 0, at: at(0)), .waitingForStart)
		XCTAssertEqual(confirmation.record(progress: nil, at: at(60)), .waitingForStart)
		XCTAssertEqual(confirmation.record(progress: 0, at: at(120)), .finished(.timedOutWaiting))
	}

	func testProgressMovesToDownloading() {
		var confirmation = confirmation()

		XCTAssertEqual(confirmation.record(progress: 0.3, at: at(5)), .downloading)
		XCTAssertEqual(confirmation.record(progress: 0.8, at: at(6)), .downloading)
	}

	func testProgressEndingAsksTheDeviceInsteadOfFinishing() {
		var confirmation = confirmation()

		verifying(&confirmation)

		XCTAssertFalse(confirmation.phase.isFinished, "Progress ending is a question, not an answer")
	}

	// MARK: - Evidence

	func testTheExpectedVersionIsInstalled() {
		var confirmation = confirmation()
		verifying(&confirmation)

		XCTAssertEqual(confirmation.record(probe: app(), at: at(11)), .finished(.installed))
	}

	func testWithoutAVersionExpectationAnyVersionCounts() {
		var confirmation = confirmation(version: nil)
		verifying(&confirmation)

		XCTAssertEqual(confirmation.record(probe: app(version: "9.9.9"), at: at(11)), .finished(.installed))
	}

	func testAnOlderVersionIsOnlyReportedAfterTheSettleWindow() {
		var confirmation = confirmation()
		verifying(&confirmation)

		XCTAssertEqual(confirmation.record(probe: app(version: "1.1.0"), at: at(12)), .verifying)
		XCTAssertEqual(
			confirmation.record(probe: app(version: "1.1.0"), at: at(31)),
			.finished(.installedOtherVersion("1.1.0"))
		)
	}

	func testAVersionThatCatchesUpInsideTheSettleWindowIsInstalled() {
		var confirmation = confirmation()
		verifying(&confirmation)

		XCTAssertEqual(confirmation.record(probe: app(version: "1.1.0"), at: at(12)), .verifying)
		XCTAssertEqual(confirmation.record(probe: app(version: "1.2.0"), at: at(20)), .finished(.installed))
	}

	func testAMissingAppIsReportedAsNotInstalledAfterTheSettleWindow() {
		var confirmation = confirmation()
		verifying(&confirmation)

		XCTAssertEqual(confirmation.record(probe: missing, at: at(12)), .verifying)
		XCTAssertEqual(confirmation.record(probe: missing, at: at(31)), .finished(.notInstalled))
	}

	func testUnknownEvidenceNeverClaimsSuccess() {
		var confirmation = confirmation()
		verifying(&confirmation)

		XCTAssertEqual(confirmation.record(probe: nil, at: at(12)), .verifying)
		XCTAssertEqual(confirmation.record(probe: nil, at: at(610)), .finished(.timedOutVerifying))
		XCTAssertFalse(InstallConfirmation.Verdict.timedOutVerifying.provesInstalled)
	}

	func testAPlaceholderIsNotAnInstall() {
		var confirmation = confirmation()
		verifying(&confirmation)

		XCTAssertEqual(confirmation.record(probe: app(placeholder: true), at: at(31)), .verifying)
		XCTAssertEqual(confirmation.record(probe: app(placeholder: true), at: at(610)), .finished(.timedOutVerifying))
	}

	// MARK: - Cancellation

	func testCancellingWhileDownloadingIsCancelled() {
		var confirmation = confirmation()
		_ = confirmation.record(progress: 0.4, at: at(1))

		XCTAssertEqual(confirmation.cancel(), .finished(.cancelled))
		XCTAssertFalse(InstallConfirmation.Verdict.cancelled.provesInstalled)
	}

	func testCancellingCannotTakeBackAProvenInstall() {
		var confirmation = confirmation()
		verifying(&confirmation)
		_ = confirmation.record(probe: app(), at: at(11))

		XCTAssertEqual(confirmation.cancel(), .finished(.installed))
	}

	// MARK: - Derivation

	func testInstalledStateDerivation() {
		XCTAssertEqual(InstalledState.derive(from: nil, expecting: "1.2.0"), .unknown)
		XCTAssertEqual(InstalledState.derive(from: missing, expecting: "1.2.0"), .notInstalled)
		XCTAssertEqual(InstalledState.derive(from: app(), expecting: "1.2.0"), .installed)
		XCTAssertEqual(InstalledState.derive(from: app(), expecting: nil), .installed)
		XCTAssertEqual(
			InstalledState.derive(from: app(version: "1.1.0"), expecting: "1.2.0"),
			.installedOtherVersion("1.1.0")
		)
		XCTAssertEqual(
			InstalledState.derive(from: app(placeholder: true), expecting: "1.2.0"),
			.unknown
		)
	}

	// MARK: - Analytics

	//'s regression: only a proven install may be counted.
	@MainActor
	func testOnlyProvenOutcomesCountAsInstalls() {
		XCTAssertTrue(AppInstaller.Outcome.installed.countsAsInstall)
		XCTAssertTrue(AppInstaller.Outcome.installedOtherVersion("1.1.0").countsAsInstall)
		XCTAssertFalse(AppInstaller.Outcome.cancelled.countsAsInstall)
		XCTAssertFalse(AppInstaller.Outcome.exported(nil).countsAsInstall)
	}

	// MARK: - Watcher

	func testWatcherReportsInstalledWhenTheDeviceShowsTheApp() async {
		let verdict = await InstallWatcher.watch(
			confirmation(),
			probe: FixedProbe(app()),
			progress: ProgressScript([0.2, 0.6, 0]).closure,
			interval: .zero
		)

		XCTAssertEqual(verdict, .installed)
	}

	func testWatcherNeverReportsSuccessWhenTheAppIsMissing() async {
		let verdict = await InstallWatcher.watch(
			confirmation(limits: .init(start: 120, verify: 600, settle: 0)),
			probe: FixedProbe(missing),
			progress: ProgressScript([0.4, 0]).closure,
			interval: .zero
		)

		XCTAssertEqual(verdict, .notInstalled)
		XCTAssertFalse(verdict.provesInstalled)
	}
}

// MARK: - Fakes

private struct FixedProbe: InstalledAppProbing {
	let app: InstalledApp?

	init(_ app: InstalledApp?) {
		self.app = app
	}

	func installedApp(for bundleIdentifier: String) -> InstalledApp? {
		app
	}
}

/// A progress counter that plays back a fixed script, then reports zero.
private final class ProgressScript: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [Double?]

	init(_ values: [Double?]) {
		self.values = values
	}

	var closure: @Sendable () async -> Double? {
		{ [self] in
			lock.lock()
			defer { lock.unlock() }
			return values.isEmpty ? 0 : values.removeFirst()
		}
	}
}
