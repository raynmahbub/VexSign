//
//  InstallConfirmationTests.swift
//  VexSignTests
//
//  Covers the install verdict: an install is reported as
//  successful only when the device says the app is there at the version that was sent, and every
//  other ending has its own answer — cancelled, rolled back, or timed out.
//
//  The engine is pure, so every transition and deadline is tested with explicit dates. Two
//  end-to-end cases drive `InstallWatcher` with a scripted progress counter and a fixed probe.
//

import Foundation
import IDeviceSwift
import os
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

	private func app(version: String? = "1.2.0", placeholder: Bool = false, bundleURL: URL? = nil) -> InstalledApp {
		InstalledApp(
			bundleIdentifier: bundleID,
			isInstalled: true,
			isPlaceholder: placeholder,
			version: version,
            bundleURL: bundleURL
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

	func testMissingAppWaitsForFullConfirmationDeadline() {
		var confirmation = confirmation()
		verifying(&confirmation)

		XCTAssertEqual(confirmation.record(probe: missing, at: at(12)), .verifying)
		XCTAssertEqual(confirmation.record(probe: missing, at: at(31)), .verifying)
        XCTAssertEqual(confirmation.record(probe: missing, at: at(610)), .finished(.notInstalled))
	}

    func testDelayedInstalledEvidenceAfterSettleStillCompletes() {
        var confirmation = confirmation()
        verifying(&confirmation)
        XCTAssertEqual(confirmation.record(probe: missing, at: at(31)), .verifying)
        XCTAssertEqual(confirmation.record(probe: app(version: "1.2.0"), at: at(45)), .finished(.installed))
    }

	func testUnknownEvidenceNeverClaimsSuccess() {
		var confirmation = confirmation()
		verifying(&confirmation)

		XCTAssertEqual(confirmation.record(probe: nil, at: at(12)), .verifying)
		XCTAssertEqual(confirmation.record(probe: nil, at: at(610)), .finished(.timedOutVerifying))
		XCTAssertFalse(InstallConfirmation.Verdict.timedOutVerifying.provesInstalled)
	}

	func testEvidenceForAnotherAppCannotConfirmInstallation() {
		var confirmation = confirmation()
		verifying(&confirmation)
		let host = InstalledApp(bundleIdentifier: "different.host", isInstalled: true, version: "1.2.0")
		XCTAssertEqual(confirmation.record(probe: host, at: at(31)), .verifying)
		XCTAssertEqual(confirmation.record(probe: host, at: at(610)), .finished(.timedOutVerifying))
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

	// 's regression: only a proven install may be counted.
	@MainActor
	func testOnlyProvenOutcomesCountAsInstalls() {
		XCTAssertTrue(AppInstaller.Outcome.installed.countsAsInstall)
		XCTAssertTrue(AppInstaller.Outcome.installedOtherVersion("1.1.0").countsAsInstall)
		XCTAssertFalse(AppInstaller.Outcome.cancelled.countsAsInstall)
		XCTAssertFalse(AppInstaller.Outcome.exported(nil).countsAsInstall)
		XCTAssertFalse(AppInstaller.Outcome.guestImportPrepared.countsAsInstall)
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

    func testWatcherAcceptsNewAppearanceWithoutProgressCounter() async {
        let verdict = await InstallWatcher.watch(
            confirmation(), probe: ScriptedProbe([missing, app()]),
            progress: ProgressScript([nil]).closure, interval: .zero
        )
        XCTAssertEqual(verdict, .installed)
    }

    func testNewAppearanceCompletesWithStuckPositiveProgress() async {
        let verdict = await InstallWatcher.watch(
            confirmation(), probe: ScriptedProbe([missing, missing, app()]),
            progress: ProgressScript([0.5, 0.5]).closure, interval: .zero
        )
        XCTAssertEqual(verdict, .installed)
    }

    func testIncompleteToFullProgressVerifiesWithoutWaitingForReset() {
        var state = confirmation()
        XCTAssertEqual(state.record(progress: 0.4, at: at(0)), .downloading)
        XCTAssertEqual(state.record(progress: 1, at: at(1)), .verifying)
        XCTAssertEqual(state.record(probe: app(), at: at(1)), .finished(.installed))
    }

    func testFullProgressStillRequiresIndependentDeviceEvidence() {
        var state = confirmation(limits: .init(start: 120, verify: 10, settle: 0))
        _ = state.record(progress: 0.4, at: at(0))
        _ = state.record(progress: 1, at: at(1))
        XCTAssertEqual(state.record(probe: nil, at: at(2)), .verifying)
        XCTAssertEqual(state.record(probe: missing, at: at(3)), .verifying)
        XCTAssertEqual(state.record(probe: missing, at: at(11)), .finished(.notInstalled))
    }

    func testInitialFullCounterCannotProveAReinstall() {
        var state = confirmation()
        XCTAssertEqual(state.record(progress: 1, at: at(0)), .downloading)
        XCTAssertEqual(state.record(progress: 1, at: at(1)), .downloading)
        XCTAssertEqual(state.record(probe: app(), at: at(1)), .downloading)
    }

    @MainActor
    func testConfirmedInstallPublishesCompletedCardBeforeQueueDismissal() {
        for outcome in [AppInstaller.Outcome.installed, .installedOtherVersion("1.1")] {
            let model = InstallerStatusViewModel(status: .installing, isIdevice: false)
            model.installProgress = 0.99
            outcome.publishConfirmedCompletion(to: model)
            XCTAssertEqual(model.installProgress, 1)
            XCTAssertTrue(model.isCompleted)
            guard case .completed(.success) = model.status else {
                XCTFail("A confirmed install must not keep displaying Installing")
                continue
            }
        }
    }

    @MainActor
    func testLateTransportCallbackCannotReopenACompletedCard() {
        let model = InstallerStatusViewModel(status: .sendingPayload, isIdevice: false)
        model.updateTransportStatus(.installing)
        XCTAssertFalse(model.isCompleted)
        AppInstaller.Outcome.installed.publishConfirmedCompletion(to: model)
        model.updateTransportStatus(.sendingPayload)
        model.updateTransportStatus(.installing)
        model.updateTransportStatus(.broken(NSError(domain: "late-stream", code: 1)))
        XCTAssertTrue(model.isCompleted)
        XCTAssertEqual(model.installProgress, 1)
    }

    @MainActor
    func testSigningExportCancellationAndGuestPreparationCannotCompleteInstallCard() {
        for outcome in [AppInstaller.Outcome.cancelled, .exported(nil), .guestImportPrepared] {
            let model = InstallerStatusViewModel(status: .installing, isIdevice: false)
            model.installProgress = 0.3
            outcome.publishConfirmedCompletion(to: model)
            XCTAssertEqual(model.installProgress, 0.3)
            XCTAssertFalse(model.isCompleted)
        }
    }

    func testStuckDownloadingCounterEntersVerificationAtDeadline() {
        var state = confirmation(limits: .init(start: 120, verify: 10, settle: 0))
        XCTAssertEqual(state.record(progress: 0.5, at: at(0)), .downloading)
        XCTAssertEqual(state.record(progress: 0.5, at: at(9)), .downloading)
        XCTAssertEqual(state.record(progress: 0.5, at: at(10)), .verifying)
        XCTAssertEqual(state.record(probe: app(), at: at(10)), .finished(.installed))
    }

    func testExistingAppWithoutProgressDoesNotProveNewInstall() async {
        let verdict = await InstallWatcher.watch(
            confirmation(limits: .init(start: 0, verify: 0, settle: 0)),
            probe: FixedProbe(app()), progress: ProgressScript([nil]).closure, interval: .zero
        )
        XCTAssertEqual(verdict, .timedOutWaiting)
    }

    func testUnknownBaselineDoesNotProveNewInstall() async {
        let verdict = await InstallWatcher.watch(
            confirmation(limits: .init(start: 0, verify: 0, settle: 0)),
            probe: ScriptedProbe([nil, app()]), progress: ProgressScript([nil]).closure, interval: .zero
        )
        XCTAssertEqual(verdict, .timedOutWaiting)
    }

    func testPrePromptBaselineCompletesAnAlreadyFinishedFastInstall() async {
        let verdict = await InstallWatcher.watch(confirmation(), probe: FixedProbe(app()),
            baseline: .init(app: missing), progress: ProgressScript([nil]).closure, interval: .zero)
        XCTAssertEqual(verdict, .installed)
    }

    func testVersionTransitionCompletesEvenWithStuckProgress() async {
        let verdict = await InstallWatcher.watch(confirmation(), probe: FixedProbe(app()),
            baseline: .init(app: app(version: "1.1.0")), progress: ProgressScript([0.8]).closure, interval: .zero)
        XCTAssertEqual(verdict, .installed)
    }

    func testExplicitlyUnknownBaselineCannotBeRecapturedAsAbsent() async {
        let verdict = await InstallWatcher.watch(
            confirmation(limits: .init(start: 0, verify: 0, settle: 0)),
            probe: ScriptedProbe([missing, app()]), baseline: .init(app: nil),
            progress: ProgressScript([nil]).closure, interval: .zero)
        XCTAssertEqual(verdict, .timedOutWaiting)
    }

    func testSlowPayloadDoesNotConsumeTheInstallStartDeadline() {
        var state = confirmation(limits: .init(start: 5, verify: 10, settle: 0))
        XCTAssertEqual(state.record(progress: nil, at: at(0), allowStartTimeout: false), .waitingForStart)
        XCTAssertEqual(state.record(progress: nil, at: at(300), allowStartTimeout: false), .waitingForStart)
        XCTAssertEqual(state.record(progress: nil, at: at(301)), .waitingForStart)
        XCTAssertEqual(state.record(progress: nil, at: at(305)), .waitingForStart)
        XCTAssertEqual(state.record(progress: nil, at: at(306)), .finished(.timedOutWaiting))
    }

    func testEarlyMonitoringCapturesProgressBeforePayloadCallback() {
        var state = confirmation()
        XCTAssertEqual(state.record(progress: 0.4, at: at(0), allowStartTimeout: false), .downloading)
        XCTAssertEqual(state.record(progress: 0, at: at(1), allowStartTimeout: false), .verifying)
        XCTAssertEqual(state.record(probe: app(), at: at(1)), .finished(.installed))
    }

    func testSameVersionReplacementContainerCompletesWithoutProgress() async {
        let before = app(bundleURL: URL(fileURLWithPath: "/var/containers/Bundle/Application/OLD/App.app"))
        let after = app(bundleURL: URL(fileURLWithPath: "/var/containers/Bundle/Application/NEW/App.app"))
        let verdict = await InstallWatcher.watch(confirmation(), probe: FixedProbe(after),
            baseline: .init(app: before), progress: ProgressScript([nil]).closure, interval: .zero)
        XCTAssertEqual(verdict, .installed)
    }

    func testObservedPlaceholderCompletesWithUnknownInitialBaselineAndNoCounter() async {
        let placeholder = app(placeholder: true)
        let verdict = await InstallWatcher.watch(confirmation(),
            probe: ScriptedProbe([placeholder, app()]), baseline: .init(app: nil),
            progress: ProgressScript([nil]).closure, interval: .zero)
        XCTAssertEqual(verdict, .installed)
    }

    func testContainerAliasesDoNotProveAReinstall() {
        let before = app(bundleURL: URL(fileURLWithPath: "/var/containers/Bundle/Application/SAME/App.app"))
        let after = app(bundleURL: URL(fileURLWithPath: "/private/var/containers/Bundle/Application/SAME/App.app"))
        XCTAssertFalse(InstallWatcher.hasNewInstalledEvidence(baseline: before, current: after,
            expectation: .init(bundleIdentifier: bundleID, version: "1.2.0")))
    }

    func testNewContainerStillRequiresInstalledMatchingNonPlaceholderApp() {
        let before = app(bundleURL: URL(fileURLWithPath: "/var/containers/Bundle/Application/OLD/App.app"))
        let path = URL(fileURLWithPath: "/var/containers/Bundle/Application/NEW/App.app")
        let expected = InstallConfirmation.Expectation(bundleIdentifier: bundleID, version: "1.2.0")
        for current in [
            app(version: "0.9", bundleURL: path),
            app(placeholder: true, bundleURL: path),
            InstalledApp(bundleIdentifier: bundleID, isInstalled: false, bundleURL: path),
            InstalledApp(bundleIdentifier: "another.bundle", isInstalled: true, version: "1.2.0", bundleURL: path)
        ] {
            XCTAssertFalse(InstallWatcher.hasNewInstalledEvidence(baseline: before, current: current, expectation: expected))
        }
        XCTAssertFalse(InstallWatcher.hasNewInstalledEvidence(baseline: nil, current: app(bundleURL: path), expectation: expected))
        XCTAssertFalse(InstallWatcher.hasNewInstalledEvidence(baseline: app(), current: app(bundleURL: path), expectation: expected))
    }

    func testNonFileURLCannotEstablishAReplacementContainer() {
        XCTAssertFalse(InstallWatcher.hasNewInstalledEvidence(
            baseline: app(bundleURL: URL(string: "https://example.invalid/old.app")),
            current: app(bundleURL: URL(string: "https://example.invalid/new.app")),
            expectation: .init(bundleIdentifier: bundleID, version: "1.2.0")))
    }

    func testSameInstalledVersionDoesNotProveAReinstall() {
        XCTAssertFalse(InstallWatcher.hasNewInstalledEvidence(baseline: app(), current: app(),
            expectation: .init(bundleIdentifier: bundleID, version: "1.2.0")))
        XCTAssertFalse(InstallWatcher.hasNewInstalledEvidence(baseline: nil, current: app(),
            expectation: .init(bundleIdentifier: bundleID, version: "1.2.0")))
    }

    func testPlaceholderMustBecomeARealInstalledApp() {
        let placeholder = InstalledApp(bundleIdentifier: bundleID, isInstalled: false, isPlaceholder: true)
        let expected = InstallConfirmation.Expectation(bundleIdentifier: bundleID, version: "1.2.0")
        XCTAssertTrue(InstallWatcher.hasNewInstalledEvidence(baseline: placeholder, current: app(), expectation: expected))
        XCTAssertFalse(InstallWatcher.hasNewInstalledEvidence(baseline: missing, current: placeholder, expectation: expected))
    }

    func testUnexpectedVersionAndWrongIdentityDoNotProveCompletion() {
        let expected = InstallConfirmation.Expectation(bundleIdentifier: bundleID, version: "1.2.0")
        XCTAssertFalse(InstallWatcher.hasNewInstalledEvidence(baseline: missing,
            current: app(version: "9.0"), expectation: expected))
        XCTAssertFalse(InstallWatcher.hasNewInstalledEvidence(baseline: missing,
            current: InstalledApp(bundleIdentifier: "other.app", isInstalled: true), expectation: expected))
    }

    func testWorkspacePositiveRepairsStaleProxyWithoutLosingVersion() {
        let stale = InstalledApp(bundleIdentifier: bundleID, isInstalled: false, version: "1.2.0",
            build: "12", bundleURL: URL(fileURLWithPath: "/private/var/containers/Bundle/Application/example/Test.app"))
        let result = InstalledAppProbe.resolve(bundleID, proxy: stale, workspaceInstalled: true)
        XCTAssertEqual(InstalledState.derive(from: result, expecting: "1.2.0"), .installed)
        XCTAssertEqual(result?.build, "12")
    }

    func testRegisteredURLAloneCannotProveInstallationOrAbsence() {
        let stale = InstalledApp(bundleIdentifier: bundleID, isInstalled: false,
            bundleURL: URL(fileURLWithPath: "/private/var/containers/Bundle/Application/example/Test.app"))
        XCTAssertNil(InstalledAppProbe.resolve(bundleID, proxy: stale, workspaceInstalled: nil))
        XCTAssertNil(InstalledAppProbe.resolve(bundleID, proxy: stale, workspaceInstalled: false))
        XCTAssertNil(InstalledAppProbe.resolve(bundleID, proxy: nil, workspaceInstalled: nil))
    }

    func testWorkspaceCannotOverrideWrongIdentityOrPlaceholder() {
        let wrong = InstalledApp(bundleIdentifier: "other.app", isInstalled: true)
        XCTAssertNil(InstalledAppProbe.resolve(bundleID, proxy: wrong, workspaceInstalled: true))
        let placeholder = InstalledApp(bundleIdentifier: bundleID, isInstalled: false, isPlaceholder: true)
        let candidate = InstalledAppProbe.resolve(bundleID, proxy: placeholder, workspaceInstalled: true)
        XCTAssertEqual(InstalledState.derive(from: candidate, expecting: nil), .unknown)
    }

    func testFilteredLegacyNegativesAreUnknownNotNotInstalled() {
        for workspace in [nil, false] as [Bool?] {
            for proxy in [nil, missing] as [InstalledApp?] {
                let result = InstalledAppProbe.resolve(bundleID, proxy: proxy, workspaceInstalled: workspace)
                XCTAssertNil(result)
                XCTAssertEqual(InstalledState.derive(from: result, expecting: nil), .unknown)
                XCTAssertNil(InstalledBadge(InstalledState.derive(from: result, expecting: nil)))
            }
        }
    }

    func testCanonicalApplicationRecordOverridesLegacyFalseWithoutLosingVersion() {
        let record = app(version: "1.2.0")
        let result = InstalledAppProbe.resolve(bundleID, proxy: missing, workspaceInstalled: false, applicationRecord: record)
        XCTAssertEqual(result, record)
        XCTAssertEqual(InstalledState.derive(from: result, expecting: "1.2.0"), .installed)
        XCTAssertEqual(InstalledState.derive(from: result, expecting: "9.0"), .installedOtherVersion("1.2.0"))
    }

    func testCanonicalRecordCannotSubstituteAnotherIdentifierOrPlaceholder() {
        let wrong = InstalledApp(bundleIdentifier: "other.app", isInstalled: true)
        XCTAssertNil(InstalledAppProbe.resolve(bundleID, proxy: nil, workspaceInstalled: true, applicationRecord: wrong))
        XCTAssertNil(InstalledAppProbe.resolve(bundleID, proxy: nil, workspaceInstalled: true, applicationRecord: app(placeholder: true)))
    }

    func testRecordValidationRequiresAnApplicationAndAnExplicitNonplaceholder() {
        func record(identifier: String? = nil, application: Bool = true, placeholder: Bool? = false,
                    systemPlaceholder: Bool? = false, url: URL? = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/example/Test.app")) -> InstalledApp? {
            InstalledAppProbe.installedRecord(bundleID, recordIdentifier: identifier ?? bundleID,
                isApplication: application, isPlaceholder: placeholder, isSystemPlaceholder: systemPlaceholder,
                version: "1.2.0", build: "12", bundleURL: url)
        }
        XCTAssertEqual(record()?.build, "12")
        XCTAssertNil(record(identifier: "another.app"))
        XCTAssertNil(record(application: false))
        XCTAssertNil(record(placeholder: nil))
        XCTAssertNil(record(placeholder: true))
        XCTAssertNil(record(systemPlaceholder: true))
        XCTAssertNil(record(url: nil))
        XCTAssertNil(record(url: URL(string: "https://example.com/Test.app")))
    }

	func testWatcherNeverReportsSuccessWhenTheAppIsMissing() async {
		let verdict = await InstallWatcher.watch(
			confirmation(limits: .init(start: 120, verify: 0, settle: 0)),
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
///
/// `OSAllocatedUnfairLock` rather than `NSLock`: `lock()`/`unlock()` are marked
/// unavailable from asynchronous contexts — an error in the Swift 6 language mode —
/// and `closure` hands progress back from exactly that kind of context.
private final class ProgressScript: Sendable {
	private let values: OSAllocatedUnfairLock<[Double?]>

	init(_ values: [Double?]) {
		self.values = OSAllocatedUnfairLock(initialState: values)
	}

	var closure: @Sendable () async -> Double? {
		{ [values] in
			values.withLock { script in
				script.isEmpty ? 0 : script.removeFirst()
			}
		}
	}
}

private final class ScriptedProbe: InstalledAppProbing {
    private let values: OSAllocatedUnfairLock<[InstalledApp?]>
    init(_ values: [InstalledApp?]) { self.values = OSAllocatedUnfairLock(initialState: values) }
    func installedApp(for bundleIdentifier: String) -> InstalledApp? {
        values.withLock { values in values.isEmpty ? nil : values.removeFirst() }
    }
}
