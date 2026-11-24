//
//  InstallDeadlineBudget.swift
//  VexSign
//
//  How long an install deadline has left, counted only while the app is running.
//
//  The installer keeps deadlines of its own beside the watcher's, for a watcher whose loop is not
//  making progress. Timed as one long sleep, such a deadline also runs out while iOS has the app
//  suspended, and so does the watcher's. Both are overdue the moment the app runs again. The
//  deadline needs one hop to act; the watcher has to ask the device first. The deadline therefore
//  won: an install that finished while the user was on the Home Screen was closed as "not
//  confirmed" a moment before the check that would have confirmed it.
//
//  The budget is spent in short waits instead. A wait that took far longer than planned means the
//  app was not running, and what is left is then at least a grace period, so a watcher that works
//  is always the one that answers. The grace can only be granted a fixed number of times: a
//  deadline has to end, whatever else happens.
//

import Foundation

struct InstallDeadlineBudget: Equatable, Sendable {
	/// Seconds of running time still to wait.
	private(set) var remaining: TimeInterval
	/// How many more times a long wait can restore the grace period.
	private(set) var extensionsLeft: Int

	/// The longest single wait. Short, so time the app spent stopped is noticed as soon as it
	/// runs again rather than at the end of the whole deadline.
	let step: TimeInterval
	/// How much longer than planned a wait has to take before the app counts as having been
	/// stopped. Wide enough that a busy main thread is not mistaken for a suspension.
	let overrun: TimeInterval
	/// The least that is left once the app runs again: enough for the watcher to read the
	/// counter and ask the device once.
	let resumeGrace: TimeInterval

	init(
		seconds: TimeInterval,
		step: TimeInterval = 5,
		overrun: TimeInterval = 5,
		resumeGrace: TimeInterval = 15,
		maximumExtensions: Int = 8
	) {
		self.remaining = seconds.isFinite ? max(0, seconds) : 0
		self.step = step.isFinite && step > 0 ? step : 5
		self.overrun = overrun.isFinite ? max(0, overrun) : 5
		self.resumeGrace = resumeGrace.isFinite ? max(0, resumeGrace) : 0
		self.extensionsLeft = max(0, maximumExtensions)
	}

	/// The next wait in seconds, or nil when the budget is spent.
	var nextWait: TimeInterval? {
		remaining > 0 ? min(remaining, step) : nil
	}

	/// The longest the budget can last in running time, every extension included.
	var longestPossible: TimeInterval {
		remaining + Double(extensionsLeft) * resumeGrace
	}

	/// Accounts for a wait that was planned to take `planned` seconds and took `elapsed`.
	mutating func spend(planned: TimeInterval, elapsed: TimeInterval) {
		guard planned.isFinite, planned > 0 else { return }
		remaining = max(0, remaining - planned)

		// A wait that ran this long was not waiting: the process was stopped for part of it,
		// and so was whatever this deadline stands behind.
		guard elapsed.isFinite, elapsed > planned + overrun, extensionsLeft > 0 else { return }
		guard remaining < resumeGrace else { return }
		remaining = resumeGrace
		extensionsLeft -= 1
	}
}

extension InstallDeadlineBudget {
	/// Waits the budget out. False when the task was cancelled first.
	///
	/// Waits are measured on the continuous clock, which keeps counting while the app is
	/// suspended: that is exactly what makes a suspension show up as a wait that ran long.
	static func wait(_ budget: InstallDeadlineBudget) async -> Bool {
		var budget = budget
		let clock = ContinuousClock()

		while let planned = budget.nextWait {
			let started = clock.now
			do {
				try await Task.sleep(for: .seconds(planned))
			} catch {
				return false
			}
			budget.spend(planned: planned, elapsed: started.duration(to: clock.now) / .seconds(1))
		}

		return !Task.isCancelled
	}

	/// Waits out `seconds` of running time with the standard grace. False when cancelled.
	static func wait(seconds: TimeInterval) async -> Bool {
		await wait(InstallDeadlineBudget(seconds: seconds))
	}
}
