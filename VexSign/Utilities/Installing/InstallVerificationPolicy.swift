//
//  InstallVerificationPolicy.swift
//  VexSign
//
//  How often, and how many times, the device is asked whether an install landed.
//
//  Verification used to ask once a second until its deadline, and gave every lookup one second
//  to answer. Two things followed. A lookup that needed longer than a second was abandoned every
//  time, so a device that was merely slow looked exactly like a device that hides the answer.
//  And nothing said how many times the device had been asked, so "Verifying installation" on
//  screen could not be told apart from a check that had stopped running.
//
//  The policy is a schedule and nothing else: a pause that grows between checks, a lookup timeout
//  that grows with it, and a count of checks that cannot be exceeded. It holds no evidence and
//  reaches no verdict. `InstallConfirmation` still decides what a reading means, and when time
//  is up.
//

import Foundation
import NimbleExtensions

struct InstallVerificationPolicy: Equatable, Sendable {
	/// The pause after the first check. The first check itself is never delayed.
	var initialDelay: TimeInterval
	/// Each pause is the one before it multiplied by this.
	var multiplier: Double
	/// No pause grows beyond this, so an install that lands late is still noticed promptly.
	var maximumDelay: TimeInterval
	/// How long the first lookup may take before the check is counted as unanswered.
	var initialProbeTimeout: TimeInterval
	/// The longest any single lookup is waited for.
	var maximumProbeTimeout: TimeInterval
	/// Whether the number of checks is capped as well as the time.
	var limitsAttempts: Bool

	init(
		initialDelay: TimeInterval = 0.5,
		multiplier: Double = 1.6,
		maximumDelay: TimeInterval = 3,
		initialProbeTimeout: TimeInterval = 1,
		maximumProbeTimeout: TimeInterval = 4,
		limitsAttempts: Bool = true
	) {
		self.initialDelay = initialDelay
		self.multiplier = multiplier
		self.maximumDelay = maximumDelay
		self.initialProbeTimeout = initialProbeTimeout
		self.maximumProbeTimeout = maximumProbeTimeout
		self.limitsAttempts = limitsAttempts
	}

	/// What an install on a device uses.
	static let standard = InstallVerificationPolicy()

	/// No pauses and no cap: checks run back to back until the engine's own deadline answers.
	/// This is the behaviour of a watcher driven with a zero interval, which is how tests feed
	/// it scripted readings without waiting on a clock.
	static let immediate = InstallVerificationPolicy(
		initialDelay: 0,
		multiplier: 1,
		maximumDelay: 0,
		initialProbeTimeout: 1,
		maximumProbeTimeout: 1,
		limitsAttempts: false
	)

	/// Checks allowed beyond the densest schedule, so the cap can never be what ends a healthy
	/// verification. A pause cut short to land on a deadline adds a check, and a check that
	/// lands a moment early - the sleep is timed by one clock and the deadline by another -
	/// adds more. The engine has three deadlines: the version-settle window, the
	/// unavailable-evidence window and the verification window. Generous on purpose: the cap
	/// is for a clock that cannot be trusted, not a second opinion on one that can.
	static let spareChecks = 16

	/// A schedule with more checks than this is not capped by count. It is still bounded by
	/// time, and a cap that could be reached before the deadline would end a healthy
	/// verification early.
	private static let countableChecks = 10_000

	// MARK: Schedule

	/// The pause after check number `attempt`, where the first check is 1.
	func delay(afterAttempt attempt: Int) -> TimeInterval {
		guard attempt >= 1, initialDelay > 0, maximumDelay > 0 else { return 0 }
		// A schedule that does not grow has one pause, whatever the attempt.
		guard multiplier > 1 else { return min(initialDelay, maximumDelay) }

		var delay = initialDelay
		var step = 1
		// Stops as soon as the ceiling is reached, so a large attempt number costs nothing and
		// the growth can never overflow.
		while step < attempt, delay < maximumDelay {
			delay *= multiplier
			step += 1
		}
		return min(delay, maximumDelay)
	}

	/// The same pause, cut short so the next check lands on the next deadline instead of after
	/// it. `untilDeadline` is nil when no deadline is known.
	func delay(afterAttempt attempt: Int, untilDeadline: TimeInterval?) -> TimeInterval {
		let planned = delay(afterAttempt: attempt)
		guard let untilDeadline else { return planned }
		return max(0, min(planned, untilDeadline))
	}

	/// How long check number `attempt` waits for the device before it counts as unanswered.
	///
	/// A lookup cannot be interrupted once it is inside the system, and while one is in flight
	/// the next is refused. Waiting longer on later checks is what lets a slow answer be read
	/// at all, instead of being abandoned at the same point every time.
	func probeTimeout(forAttempt attempt: Int) -> TimeInterval {
		guard attempt >= 1, initialProbeTimeout > 0, multiplier > 1 else { return max(0, initialProbeTimeout) }

		var timeout = initialProbeTimeout
		var step = 1
		while step < attempt, timeout < maximumProbeTimeout {
			timeout *= multiplier
			step += 1
		}
		return max(initialProbeTimeout, min(timeout, maximumProbeTimeout))
	}

	/// The same timeout, cut short when a deadline is closer than it: the last check before a
	/// deadline must not hold the answer back for longer than the first one would have.
	func probeTimeout(forAttempt attempt: Int, untilDeadline: TimeInterval?) -> TimeInterval {
		let planned = probeTimeout(forAttempt: attempt)
		guard let untilDeadline else { return planned }
		return min(planned, max(initialProbeTimeout, untilDeadline))
	}

	/// The most checks a verification window of `budget` seconds can hold.
	///
	/// Counted as if every lookup answered instantly, which is the densest the schedule can
	/// be. A real run therefore reaches its deadline first; the cap is only reached when time
	/// itself cannot be trusted, such as the device clock being set back during an install.
	/// Returns nil when the checks are not capped.
	func maximumAttempts(within budget: TimeInterval) -> Int? {
		guard limitsAttempts, initialDelay > 0, maximumDelay > 0 else { return nil }
		guard budget > 0 else { return 1 + Self.spareChecks }

		var attempts = 1
		var elapsed: TimeInterval = 0
		while elapsed < budget {
			guard attempts < Self.countableChecks else { return nil }
			elapsed += delay(afterAttempt: attempts)
			attempts += 1
		}
		return attempts + Self.spareChecks
	}

	// MARK: Wording

	/// The status line while the device is being asked.
	///
	/// The first check keeps the plain wording, because a count of one says nothing more. From
	/// the second on the count is shown, so a card that is still waiting visibly moves.
	static func statusLabel(attempt: Int) -> String {
		guard attempt > 1 else { return .localized("Verifying installation") }
		return .localized("Verifying installation (check %lld)", arguments: attempt)
	}
}
