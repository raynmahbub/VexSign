//
//  InstallVerificationTests.swift
//  VexSignTests
//
//  How the device is asked whether an install landed: how often, how many times, and what one
//  unanswered check is allowed to mean.
//
//  Three things are covered. The schedule is a pure function, tested as one. The engine's rule
//  for an unanswered check is tested with explicit dates. And the watcher itself is replayed
//  against a scripted device whose clock only moves when it is asked, so a deadline, a missed
//  check and a clock that stands still are all reproduced exactly, without waiting on real time.
//

import Foundation
import XCTest
@testable import VexSign

final class InstallVerificationTests: XCTestCase {
	private let bundleID = "com.example.app"
	private let epoch = Date(timeIntervalSince1970: 1_000_000)

	private func at(_ seconds: TimeInterval) -> Date {
		epoch.addingTimeInterval(seconds)
	}

	private var installed: InstalledApp {
		InstalledApp(bundleIdentifier: bundleID, isInstalled: true, version: "1.2.0")
	}

	private var placeholder: InstalledApp {
		InstalledApp(bundleIdentifier: bundleID, isInstalled: true, isPlaceholder: true, version: "1.2.0")
	}

	private func waiting(_ limits: InstallConfirmation.Limits = InstallConfirmation.Limits()) -> InstallConfirmation {
		InstallConfirmation(expectation: .init(bundleIdentifier: bundleID, version: "1.2.0"), limits: limits)
	}

	/// An engine whose verification started at `epoch`, so a date is also the time spent verifying.
	private func verifying(_ limits: InstallConfirmation.Limits = InstallConfirmation.Limits()) -> InstallConfirmation {
		var confirmation = waiting(limits)
		XCTAssertEqual(confirmation.beginVerifying(at: epoch), .verifying)
		return confirmation
	}

	// MARK: - Schedule

	func testPausesGrowFromHalfASecondToThreeSeconds() {
		let policy = InstallVerificationPolicy.standard

		XCTAssertEqual(policy.delay(afterAttempt: 0), 0, accuracy: 1e-9)
		XCTAssertEqual(policy.delay(afterAttempt: 1), 0.5, accuracy: 1e-9)
		XCTAssertEqual(policy.delay(afterAttempt: 2), 0.8, accuracy: 1e-9)
		XCTAssertEqual(policy.delay(afterAttempt: 3), 1.28, accuracy: 1e-9)
		XCTAssertEqual(policy.delay(afterAttempt: 4), 2.048, accuracy: 1e-9)
		XCTAssertEqual(policy.delay(afterAttempt: 5), 3, accuracy: 1e-9)
		XCTAssertEqual(policy.delay(afterAttempt: 1_000_000), 3, accuracy: 1e-9)
	}

	func testAPauseIsCutShortToLandOnTheNextDeadline() {
		let policy = InstallVerificationPolicy.standard

		XCTAssertEqual(policy.delay(afterAttempt: 9, untilDeadline: nil), 3, accuracy: 1e-9)
		XCTAssertEqual(policy.delay(afterAttempt: 9, untilDeadline: 50), 3, accuracy: 1e-9)
		XCTAssertEqual(policy.delay(afterAttempt: 9, untilDeadline: 0.4), 0.4, accuracy: 1e-9)
		XCTAssertEqual(policy.delay(afterAttempt: 9, untilDeadline: -1), 0, accuracy: 1e-9)
	}

	func testALookupIsGivenLongerOnLaterChecksButNeverPastADeadline() {
		let policy = InstallVerificationPolicy.standard

		XCTAssertEqual(policy.probeTimeout(forAttempt: 1), 1, accuracy: 1e-9)
		XCTAssertEqual(policy.probeTimeout(forAttempt: 2), 1.6, accuracy: 1e-9)
		XCTAssertEqual(policy.probeTimeout(forAttempt: 3), 2.56, accuracy: 1e-9)
		XCTAssertEqual(policy.probeTimeout(forAttempt: 4), 4, accuracy: 1e-9)
		XCTAssertEqual(policy.probeTimeout(forAttempt: 500), 4, accuracy: 1e-9)

		XCTAssertEqual(policy.probeTimeout(forAttempt: 9, untilDeadline: nil), 4, accuracy: 1e-9)
		// Close to a deadline a lookup may not hold the answer back...
		XCTAssertEqual(policy.probeTimeout(forAttempt: 9, untilDeadline: 2), 2, accuracy: 1e-9)
		// ...but it is never given less than the first lookup was.
		XCTAssertEqual(policy.probeTimeout(forAttempt: 9, untilDeadline: 0.1), 1, accuracy: 1e-9)
	}

	func testBackToBackChecksNeverPauseEscalateOrRunOut() {
		let policy = InstallVerificationPolicy.immediate

		XCTAssertEqual(policy.delay(afterAttempt: 5), 0, accuracy: 1e-9)
		XCTAssertEqual(policy.delay(afterAttempt: 5, untilDeadline: 10), 0, accuracy: 1e-9)
		XCTAssertEqual(policy.probeTimeout(forAttempt: 9), 1, accuracy: 1e-9)
		XCTAssertNil(policy.maximumAttempts(within: 120))
	}

	func testTheCheckCapGrowsWithTheWindow() throws {
		let policy = InstallVerificationPolicy.standard

		let short = try XCTUnwrap(policy.maximumAttempts(within: 30))
		let standard = try XCTUnwrap(policy.maximumAttempts(within: 120))
		let update = try XCTUnwrap(policy.maximumAttempts(within: 600))

		XCTAssertLessThan(short, standard)
		XCTAssertLessThan(standard, update)
		XCTAssertEqual(policy.maximumAttempts(within: 0), 1 + InstallVerificationPolicy.spareChecks)

		// What the standard schedule comes to: 14, 44 and 204 checks fit in these windows when
		// every lookup answers at once, and the spare checks are added to each. Pinned so that
		// a change to the schedule or to the allowance shows up as a change to the cap.
		XCTAssertEqual(InstallVerificationPolicy.spareChecks, 16)
		XCTAssertEqual(short, 30)
		XCTAssertEqual(standard, 60)
		XCTAssertEqual(update, 220)
	}

	/// The cap exists for a clock that cannot be trusted. It must never be what ends a
	/// verification whose clock works, whatever the device answers and however long the window.
	func testAHealthyVerificationReachesItsDeadlineBeforeTheCap() throws {
		let policy = InstallVerificationPolicy.standard
		let windows: [InstallConfirmation.Limits] = [
			InstallConfirmation.Limits(),
			// The limits the self-update flow uses.
			InstallConfirmation.Limits(start: 40, verify: 600, settle: 20)
		]

		for limits in windows {
			let cap = try XCTUnwrap(policy.maximumAttempts(within: limits.verify))

			// The app stays a placeholder: the full window, at the densest the schedule gets.
			let full = _replay(reading: placeholder, limits: limits, policy: policy, lookup: 0)
			XCTAssertEqual(full.phase, .finished(.timedOutVerifying))
			XCTAssertLessThan(full.attempts, cap, "verify \(limits.verify)")
			XCTAssertEqual(full.elapsed, limits.verify, accuracy: 0.001, "The last check lands on the deadline")

			// The device never answers: the short window.
			let silent = _replay(reading: nil, limits: limits, policy: policy, lookup: 0)
			XCTAssertEqual(silent.phase, .finished(.timedOutVerifying))
			XCTAssertLessThan(silent.attempts, cap)
			XCTAssertEqual(silent.elapsed, limits.unavailableEvidence, accuracy: 0.001)

			// Slow lookups only ever make the run sparser.
			let slow = _replay(reading: placeholder, limits: limits, policy: policy, lookup: 2.5)
			XCTAssertLessThan(slow.attempts, full.attempts)
		}
	}

	func testTheStatusLineCountsFromTheSecondCheck() {
		let first = InstallVerificationPolicy.statusLabel(attempt: 1)

		XCTAssertFalse(first.isEmpty)
		XCTAssertEqual(InstallVerificationPolicy.statusLabel(attempt: 0), first)
		XCTAssertNotEqual(InstallVerificationPolicy.statusLabel(attempt: 2), first)
		XCTAssertTrue(InstallVerificationPolicy.statusLabel(attempt: 7).contains("7"))
	}

	// MARK: - One unanswered check

	func testAMissedCheckBetweenTwoAnswersDoesNotEndVerification() {
		var confirmation = verifying()

		XCTAssertEqual(confirmation.record(probe: placeholder, at: at(29)), .verifying)
		// Past the short deadline, one check goes unanswered. The device answered two seconds ago.
		XCTAssertEqual(confirmation.record(probe: nil, at: at(31)), .verifying)
		XCTAssertEqual(confirmation.record(probe: placeholder, at: at(34)), .verifying)
		XCTAssertEqual(confirmation.record(probe: installed, at: at(40)), .finished(.installed))
	}

	func testEvidenceThatStopsArrivingEndsOnceTheGraceHasPassed() {
		var confirmation = verifying()

		XCTAssertEqual(confirmation.record(probe: placeholder, at: at(29)), .verifying)
		XCTAssertEqual(confirmation.record(probe: nil, at: at(31)), .verifying)
		XCTAssertEqual(confirmation.record(probe: nil, at: at(38)), .verifying)
		XCTAssertEqual(confirmation.record(probe: nil, at: at(39)), .finished(.timedOutVerifying))
	}

	func testADeviceThatNeverAnswersKeepsTheShortDeadline() {
		var confirmation = verifying()

		XCTAssertEqual(confirmation.record(probe: nil, at: at(29)), .verifying)
		XCTAssertEqual(confirmation.record(probe: nil, at: at(30)), .finished(.timedOutVerifying))
	}

	func testTheGraceNeverOutlivesTheVerificationWindow() {
		var confirmation = verifying()

		XCTAssertEqual(confirmation.record(probe: placeholder, at: at(119)), .verifying)
		XCTAssertEqual(confirmation.record(probe: nil, at: at(120)), .finished(.timedOutVerifying))
	}

	func testAnUnansweredCheckNeverBecomesASuccess() {
		var confirmation = verifying()

		XCTAssertEqual(confirmation.record(probe: installed.with(version: "1.1.0"), at: at(5)), .verifying)
		XCTAssertEqual(confirmation.record(probe: nil, at: at(6)), .verifying)
		XCTAssertNil(confirmation.phase.verdict)
	}

	// MARK: - Deadlines and running out of checks

	func testTheNextDeadlineWalksThroughSettleUnavailableAndVerify() {
		var confirmation = waiting()
		XCTAssertNil(confirmation.secondsUntilNextDeadline(at: epoch), "Nothing is timed before verification starts")

		XCTAssertEqual(confirmation.beginVerifying(at: epoch), .verifying)
		XCTAssertEqual(confirmation.secondsUntilNextDeadline(at: at(0)), 20)
		XCTAssertEqual(confirmation.secondsUntilNextDeadline(at: at(20)), 10)
		XCTAssertEqual(confirmation.secondsUntilNextDeadline(at: at(30)), 90)
		XCTAssertEqual(confirmation.secondsUntilNextDeadline(at: at(119)), 1)
		XCTAssertNil(confirmation.secondsUntilNextDeadline(at: at(120)))

		XCTAssertEqual(confirmation.record(probe: installed, at: at(121)), .finished(.installed))
		XCTAssertNil(confirmation.secondsUntilNextDeadline(at: at(121)))
	}

	func testRunningOutOfChecksIsUnconfirmedAndNeverASuccess() {
		var notStarted = waiting()
		XCTAssertEqual(notStarted.endVerificationUnconfirmed(), .waitingForStart, "Only a verification can run out of checks")

		var confirmation = verifying()
		XCTAssertEqual(confirmation.endVerificationUnconfirmed(), .finished(.timedOutVerifying))
		XCTAssertFalse(InstallConfirmation.Verdict.timedOutVerifying.provesInstalled)

		var proven = verifying()
		XCTAssertEqual(proven.record(probe: installed, at: at(1)), .finished(.installed))
		XCTAssertEqual(proven.endVerificationUnconfirmed(), .finished(.installed), "A proven install cannot be taken back")
	}

	func testTheMonitoringBackstopOutlastsEveryPhaseLimit() {
		let limits = InstallConfirmation.Limits()
		XCTAssertEqual(limits.evidenceGrace, 10)
		XCTAssertEqual(limits.monitoringBackstop, 390)

		// The longest a watcher that is working can take once the payload is served: waiting,
		// the counter and verification each at their limit, every limit noticed one sample
		// late (a one-second pause and a one-second lookup), and the last check waited out.
		let sample: TimeInterval = 1 + 1
		let slowest = limits.start + limits.verify + limits.verify
			+ 3 * sample + InstallVerificationPolicy.standard.maximumProbeTimeout
		XCTAssertGreaterThanOrEqual(limits.monitoringBackstop, slowest + 10, "The backstop must never be what ends a healthy install")

		let update = InstallConfirmation.Limits(start: 40, verify: 600, settle: 20)
		XCTAssertGreaterThan(update.monitoringBackstop, update.start + update.verify + update.verify)
	}

	// MARK: - The watcher, on scripted time

	func testEveryDeviceCheckIsReportedInOrder() async {
		let device = ScriptedDevice([placeholder, placeholder, installed], startingAt: epoch, step: 1)
		let attempts = Recorder<Int>()
		var confirmation = verifying()

		let verdict = await InstallWatcher.confirm(
			&confirmation,
			probe: device,
			interval: .zero,
			onAttempt: { attempts.append($0) },
			now: { device.now }
		)

		XCTAssertEqual(verdict, .installed)
		XCTAssertEqual(attempts.values, [1, 2, 3])
	}

	func testAMissedCheckDoesNotStopTheWatcher() async {
		// Five seconds of device time per check. The seventh goes unanswered, at 35 seconds:
		// past the short deadline, and five seconds after the device last answered.
		let readings: [InstalledApp?] = [
			placeholder, placeholder, placeholder, placeholder, placeholder, placeholder,
			nil, placeholder, installed
		]
		let device = ScriptedDevice(readings, startingAt: epoch, step: 5)
		let attempts = Recorder<Int>()
		var confirmation = verifying()

		let verdict = await InstallWatcher.confirm(
			&confirmation,
			probe: device,
			interval: .zero,
			onAttempt: { attempts.append($0) },
			now: { device.now }
		)

		XCTAssertEqual(verdict, .installed)
		XCTAssertEqual(attempts.values.count, 9)
	}

	func testEvidenceThatStaysAwayEndsTheWatcherUnconfirmed() async {
		// Placeholders until 25 seconds, then nothing. The check at 30 is still within the grace;
		// the one at 35 is not.
		let readings: [InstalledApp?] = [placeholder, placeholder, placeholder, placeholder, placeholder, nil]
		let device = ScriptedDevice(readings, startingAt: epoch, step: 5)
		let attempts = Recorder<Int>()
		var confirmation = verifying()

		let verdict = await InstallWatcher.confirm(
			&confirmation,
			probe: device,
			interval: .zero,
			onAttempt: { attempts.append($0) },
			now: { device.now }
		)

		XCTAssertEqual(verdict, .timedOutVerifying)
		XCTAssertFalse(verdict.provesInstalled)
		XCTAssertEqual(attempts.values.count, 7)
	}

	func testADeviceThatNeverAnswersEndsTheWatcherAtTheShortDeadline() async {
		let device = ScriptedDevice([nil], startingAt: epoch, step: 5)
		let attempts = Recorder<Int>()
		var confirmation = verifying()

		let verdict = await InstallWatcher.confirm(
			&confirmation,
			probe: device,
			interval: .zero,
			onAttempt: { attempts.append($0) },
			now: { device.now }
		)

		XCTAssertEqual(verdict, .timedOutVerifying)
		XCTAssertEqual(attempts.values.count, 6, "Checks at 5 to 30 seconds; the one at 30 ends it")
	}

	/// A clock that never moves keeps every deadline out of reach, which is what a device clock
	/// set back during an install does. The number of checks is what still ends the loop.
	func testTheCheckCapEndsVerificationWhenTheClockStandsStill() async throws {
		let limits = InstallConfirmation.Limits(start: 120, verify: 0.01, settle: 0.005)
		let policy = InstallVerificationPolicy(initialDelay: 0.001, multiplier: 1, maximumDelay: 0.001)
		let cap = try XCTUnwrap(policy.maximumAttempts(within: limits.verify))
		let device = ScriptedDevice([placeholder], startingAt: epoch, step: 0)
		let attempts = Recorder<Int>()
		var confirmation = verifying(limits)

		let verdict = await InstallWatcher.confirm(
			&confirmation,
			probe: device,
			policy: policy,
			onAttempt: { attempts.append($0) },
			now: { device.now }
		)

		XCTAssertEqual(verdict, .timedOutVerifying)
		XCTAssertFalse(verdict.provesInstalled)
		XCTAssertEqual(attempts.values.count, cap)
		XCTAssertEqual(device.lookups, cap)
	}

	func testAnInstallThatLandsOnTheLastAllowedCheckIsStillInstalled() async throws {
		let limits = InstallConfirmation.Limits(start: 120, verify: 0.01, settle: 0.005)
		let policy = InstallVerificationPolicy(initialDelay: 0.001, multiplier: 1, maximumDelay: 0.001)
		let cap = try XCTUnwrap(policy.maximumAttempts(within: limits.verify))
		let readings = [InstalledApp?](repeating: placeholder, count: cap - 1) + [installed]
		let device = ScriptedDevice(readings, startingAt: epoch, step: 0)
		var confirmation = verifying(limits)

		let verdict = await InstallWatcher.confirm(
			&confirmation,
			probe: device,
			policy: policy,
			now: { device.now }
		)

		XCTAssertEqual(verdict, .installed, "Evidence outranks the cap")
	}

	func testTheWatcherReportsChecksThroughItsPublicEntryPoint() async {
		// The first two readings are taken while the counter is still running; the checks that
		// are counted start once progress has ended.
		let readings: [InstalledApp?] = [placeholder, placeholder, placeholder, placeholder, installed]
		let device = ScriptedDevice(readings, startingAt: epoch, step: 1)
		let progress = Script<Double?>([0.4], then: 0)
		let attempts = Recorder<Int>()

		let verdict = await InstallWatcher.watch(
			waiting(),
			probe: device,
			baseline: .init(app: nil),
			progress: { progress.next() },
			interval: .zero,
			onVerificationAttempt: { attempts.append($0) },
			now: { device.now }
		)

		XCTAssertEqual(verdict, .installed)
		XCTAssertEqual(attempts.values, [1, 2, 3])
	}

	// MARK: - Replay

	/// The watcher's loop on a synthetic clock, so a whole verification window is replayed in no
	/// time: every lookup takes `lookup` seconds and returns `reading`.
	private func _replay(
		reading: InstalledApp?,
		limits: InstallConfirmation.Limits,
		policy: InstallVerificationPolicy,
		lookup: TimeInterval
	) -> (attempts: Int, phase: InstallConfirmation.Phase, elapsed: TimeInterval) {
		var confirmation = verifying(limits)
		var clock: TimeInterval = 0
		var attempt = 0

		while attempt < 100_000 {
			attempt += 1
			clock += lookup
			let phase = confirmation.record(probe: reading, at: at(clock))
			if phase.isFinished { return (attempt, phase, clock) }
			clock += policy.delay(
				afterAttempt: attempt,
				untilDeadline: confirmation.secondsUntilNextDeadline(at: at(clock))
			)
		}

		return (attempt, confirmation.phase, clock)
	}
}

// MARK: - Fakes

private extension InstalledApp {
	func with(version: String) -> InstalledApp {
		InstalledApp(
			bundleIdentifier: bundleIdentifier,
			isInstalled: isInstalled,
			isPlaceholder: isPlaceholder,
			version: version,
			build: build,
			bundleURL: bundleURL
		)
	}
}

/// A device and its clock in one. Every lookup moves the clock on by `step` and answers with the
/// next scripted reading; the last reading repeats. Time therefore passes only when the device
/// is asked, which makes every deadline land on a known check.
///
/// `@unchecked Sendable`: the state is only touched under the lock, from synchronous methods.
private final class ScriptedDevice: InstalledAppProbing, @unchecked Sendable {
	private let lock = NSLock()
	private var readings: [InstalledApp?]
	private var date: Date
	private var count = 0
	private let step: TimeInterval

	init(_ readings: [InstalledApp?], startingAt date: Date, step: TimeInterval) {
		self.readings = readings
		self.date = date
		self.step = step
	}

	func installedApp(for bundleIdentifier: String) -> InstalledApp? {
		lock.lock()
		defer { lock.unlock() }
		date = date.addingTimeInterval(step)
		count += 1
		if readings.count > 1 { return readings.removeFirst() }
		return readings.first ?? nil
	}

	var now: Date {
		lock.lock()
		defer { lock.unlock() }
		return date
	}

	var lookups: Int {
		lock.lock()
		defer { lock.unlock() }
		return count
	}
}

/// Collects what a `@Sendable` callback is told.
private final class Recorder<Value>: @unchecked Sendable {
	private let lock = NSLock()
	private var items: [Value] = []

	func append(_ value: Value) {
		lock.lock()
		defer { lock.unlock() }
		items.append(value)
	}

	var values: [Value] {
		lock.lock()
		defer { lock.unlock() }
		return items
	}
}

/// Plays back a fixed script, then keeps answering with `fallback`.
private final class Script<Value>: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [Value]
	private let fallback: Value

	init(_ values: [Value], then fallback: Value) {
		self.values = values
		self.fallback = fallback
	}

	func next() -> Value {
		lock.lock()
		defer { lock.unlock() }
		return values.isEmpty ? fallback : values.removeFirst()
	}
}
