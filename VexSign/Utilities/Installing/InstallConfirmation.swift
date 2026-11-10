//
//  InstallConfirmation.swift
//  VexSign
//
//  Decides when an install is really finished, and on what evidence.
//
//  The rule this replaces: "progress went back to zero, therefore installed". installd's counter
//  reaching zero means installd stopped — it does not mean the app is on the device. iOS rolls
//  the install back when it rejects a signature or a profile, and a user who declines the prompt
//  produces the same silence.
//
//  The engine here is pure: it is fed progress samples and probe readings with explicit dates and
//  answers with a phase. `InstallWatcher` is the small loop that supplies them. Neither one
//  guesses: with no evidence the verdict is a timeout, never a success.
//

import Foundation
import NimbleExtensions

// MARK: - Engine

struct InstallConfirmation: Equatable, Sendable {
	/// What the caller sent, and therefore what the device should end up reporting.
	struct Expectation: Equatable, Sendable {
		let bundleIdentifier: String
		let version: String?
		let build: String?

		init(bundleIdentifier: String, version: String? = nil, build: String? = nil) {
			self.bundleIdentifier = bundleIdentifier
			self.version = version
			self.build = build
		}
	}

	/// How long each phase may take before the install is called off.
	struct Limits: Equatable, Sendable {
		static let defaultVerifySeconds: Int64 = 120

		/// How long the prompt may sit unanswered before nothing is going to happen.
		var start: TimeInterval = 120
		/// Maximum time to wait for installation evidence after progress ends. A
		/// placeholder is useful activity, but it must not leave the queue spinning
		/// indefinitely when iOS never publishes a completed app record.
		var verify: TimeInterval = TimeInterval(Self.defaultVerifySeconds)
		/// How long the device gets to show the app, or to report the new version.
		var settle: TimeInterval = 20
        /// Unreadable/filtered evidence should end promptly; this remains shorter than
        /// the bounded window granted when iOS positively reports a placeholder.
        var unavailableEvidence: TimeInterval = 30
		/// How long after the device last answered a check may go unanswered before the evidence
		/// counts as unavailable. One lookup that is refused or times out is a missed check; it
		/// does not turn a device that was reporting the app a moment ago into one that hides it.
		var evidenceGrace: TimeInterval = 10

		/// The longest one install may be monitored once its payload has been handed to iOS:
		/// every phase at its own limit, plus room for the samples and the last check that sit
		/// between them. A caller that cannot rely on its polling loop making progress bounds
		/// the whole attempt with this.
		var monitoringBackstop: TimeInterval { start + verify * 2 + 30 }
	}

	enum Phase: Equatable, Sendable {
		case waitingForStart
		case downloading
		case verifying
		case finished(Verdict)

		var verdict: Verdict? {
			guard case .finished(let verdict) = self else { return nil }
			return verdict
		}

		var isFinished: Bool { verdict != nil }
	}

	enum Verdict: Equatable, Sendable {
		/// The device reports the app, at the version that was sent.
		case installed
		/// The device reports the app, at another version. Proven installed, not proven current.
		case installedOtherVersion(String?)
        /// No installed app was reported by the deadline; not a rejection diagnosis.
		case notInstalled
		/// No start was observed before the deadline; the dialog decision is unknown.
		case timedOutWaiting
		/// Progress ended, and the device never showed the app in time.
		case timedOutVerifying
		/// The user (or the caller) called it off.
		case cancelled

		var provesInstalled: Bool {
			switch self {
			case .installed, .installedOtherVersion:
				true
			case .notInstalled, .timedOutWaiting, .timedOutVerifying, .cancelled:
				false
			}
		}
	}

	let expectation: Expectation
	let limits: Limits
	private(set) var phase: Phase = .waitingForStart

	private var _downloadingSince: Date?
    private var _observedIncompleteProgress = false
	private var _waitingSince: Date?
	private var _verifyingAt: Date?
	/// When the device last answered a verification check with a record of any kind.
	private var _lastReadingAt: Date?

	init(expectation: Expectation, limits: Limits = Limits()) {
		self.expectation = expectation
		self.limits = limits
	}

	// MARK: Progress

	/// Feeds one progress sample. `nil` means the device could not read the counter at all.
	mutating func record(progress: Double?, at date: Date, allowStartTimeout: Bool = true) -> Phase {
		guard !phase.isFinished else { return phase }

		if (progress ?? 0) > 0 {
			if phase == .waitingForStart {
                _downloadingSince = date
                phase = .downloading
            }
            if let progress, progress.isFinite, progress > 0, progress < 1 {
                _observedIncompleteProgress = true
            }
            // Some iOS versions leave the counter at 100% rather than resetting
            // it. A real in-progress -> full transition can start verification;
            // an initial/stale full counter alone cannot bypass the deadline.
            if let progress, progress.isFinite, progress >= 1, _observedIncompleteProgress,
               phase == .downloading {
                return beginVerifying(at: date)
            }
            if phase == .downloading,
               date.timeIntervalSince(_downloadingSince ?? date) >= limits.verify {
                // A stuck nonzero counter must not keep the install card alive forever.
                return beginVerifying(at: date)
            }
			return phase
		}

		switch phase {
		case .waitingForStart:
            // Observe during payload transfer, but do not charge a slow transfer
            // against the time allowed for iOS to begin installing it.
            guard allowStartTimeout else {
                _waitingSince = nil
                return phase
            }
			// Counted from the first sample, so a caller that starts watching late still times out.
			_waitingSince = _waitingSince ?? date
			if date.timeIntervalSince(_waitingSince ?? date) >= limits.start {
				return _finish(.timedOutWaiting)
			}
			return phase

		case .downloading:
			// Progress is back at zero: installd has stopped. That is a question, not an answer.
			_verifyingAt = date
			phase = .verifying
			return phase

		case .verifying, .finished:
			return phase
		}
	}

	/// Enters the verification phase directly.
	///
	/// Used by the IDevice path, where installd reports completion itself and there is no
	/// progress counter to watch — the question is still the same one.
	mutating func beginVerifying(at date: Date) -> Phase {
		guard !phase.isFinished else { return phase }
		if _waitingSince == nil { _waitingSince = date }
		_verifyingAt = date
		phase = .verifying
		return phase
	}

	// MARK: Evidence

	/// Feeds one probe reading. Only meaningful once progress has ended.
	mutating func record(probe: InstalledApp?, at date: Date) -> Phase {
		guard !phase.isFinished else { return phase }
		guard phase == .verifying else { return phase }

		let verifyStart = _verifyingAt ?? date
		let settled = date.timeIntervalSince(verifyStart) >= limits.settle

		// Judged before this reading is recorded: whether the device was still answering when
		// this check went out.
		let answeredRecently = _lastReadingAt.map { date.timeIntervalSince($0) < limits.evidenceGrace } ?? false
		if probe != nil { _lastReadingAt = date }

        var matchingProbe = probe?.bundleIdentifier == expectation.bundleIdentifier ? probe : nil
        // Missing or mismatched build metadata cannot establish the requested artifact.
        if let expectedBuild = expectation.build, matchingProbe?.build != expectedBuild {
            matchingProbe = nil
        }
        if expectation.version != nil && matchingProbe?.version == nil && matchingProbe?.isInstalled == true {
            matchingProbe = nil
        }
		switch InstalledState.derive(from: matchingProbe, expecting: expectation.version) {
		case .installed:
			return _finish(.installed)

		case .installedOtherVersion(let version):
			// The version string can lag the install by a moment; only call it different once it
			// has had the settle window to catch up.
			return settled ? _finish(.installedOtherVersion(version)) : phase

        case .notInstalled:
            // LaunchServices can lag or hide an app while iOS finishes installing.
            // A negative reading at the short version-settle deadline is not a
            // rollback. Keep checking until the full confirmation deadline.
            if date.timeIntervalSince(verifyStart) >= limits.verify {
                return _finish(.notInstalled)
            }

		case .unknown:
			// Two different kinds of "unknown". A placeholder is positive evidence
			// that iOS registered the app and is still writing it, so it gets the
			// full verification window. Only a probe that returned nothing at all
			// hits the short deadline that stops the UI spinning forever.
			//
			// "Nothing at all" has to last, though. The lookup is refused while another one
			// is in flight and abandoned when it is slow, so a single empty reading between
			// two placeholder readings is routine. Ending on it reported an install that was
			// still being written as unconfirmed, the moment the short deadline had passed.
			let evidenceIsUnavailable = probe == nil && !answeredRecently
			let deadline = evidenceIsUnavailable
				? min(limits.verify, limits.unavailableEvidence)
				: limits.verify
			if date.timeIntervalSince(verifyStart) >= deadline {
				return _finish(.timedOutVerifying)
			}

		case .installing:
			// Unreachable from `derive`, which only ever answers from device evidence: the
			// transient lifecycle state is the library's, and the confirmation engine is what
			// decides when it ends. Handled so the switch stays exhaustive and honest.
			break
		}

		if date.timeIntervalSince(verifyStart) >= limits.verify {
			return _finish(.timedOutVerifying)
		}

		return phase
	}

	/// Seconds from `date` until the next moment the verdict can change through time alone, or
	/// nil when not verifying or when every deadline has passed.
	///
	/// The watcher spaces its checks out; this is what lets it still land one on each deadline
	/// instead of up to a whole pause after it.
	func secondsUntilNextDeadline(at date: Date) -> TimeInterval? {
		guard phase == .verifying, let start = _verifyingAt else { return nil }
		let elapsed = date.timeIntervalSince(start)
		let marks = [limits.settle, min(limits.verify, limits.unavailableEvidence), limits.verify]
		return marks.filter { $0 > elapsed }.min().map { $0 - elapsed }
	}

	/// Ends verification without an answer because the caller has no checks left.
	///
	/// The same verdict as running out of time: not a rejection, and never a success.
	mutating func endVerificationUnconfirmed() -> Phase {
		guard phase == .verifying else { return phase }
		return _finish(.timedOutVerifying)
	}

	// MARK: Cancellation

	/// A user-driven cancel. It cannot take back an install the device has already proven.
	mutating func cancel() -> Phase {
		guard !phase.isFinished else { return phase }
		return _finish(.cancelled)
	}

	private mutating func _finish(_ verdict: Verdict) -> Phase {
		phase = .finished(verdict)
		return phase
	}
}

extension InstallConfirmation {
    struct Failure: LocalizedError {
        let verdict: Verdict
        var errorDescription: String? { verdict.message }
    }
}

// MARK: - Verdict text

extension InstallConfirmation.Verdict {
    var diagnosticCode: String {
        switch self {
        case .installed: return "device-confirmed-installed"
        case .installedOtherVersion: return "device-reports-other-version"
        case .notInstalled: return "device-did-not-report-installed-app"
        case .timedOutWaiting: return "install-start-not-observed"
        case .timedOutVerifying: return "installation-evidence-unavailable"
        case .cancelled: return "cancelled"
        }
    }
	/// User-facing explanation, or nil when there is nothing to say.
	var message: String? {
		switch self {
		case .installed, .cancelled:
			nil
		case .installedOtherVersion(let version):
			.localized(
				"Installed, but the device reports version %@.",
				arguments: version ?? .localized("unknown")
			)
		case .notInstalled:
			.localized("The installation could not be confirmed: iOS did not report the expected app after the install attempt. A rejected signing certificate, incompatible profile or bundle, or an unavailable installation-status check can cause this. Review the task report and device installation logs before signing again.")
		case .timedOutWaiting:
			.localized("The installation request was not confirmed. iOS does not report whether the prompt was accepted or declined. Check the Home Screen before retrying.")
		case .timedOutVerifying:
			.localized("VexSign could not confirm the installation. If the app is on your Home Screen, open it there. Otherwise check installation details before retrying.")
		}
	}
}

// MARK: - Watcher

/// Polls install progress, then the device, and reports what actually happened.
///
/// Both install paths feed the same engine through this loop, so there is one rule for what
/// "installed" means. The I/O is injected, which is also what makes it testable.
enum InstallWatcher {
    /// Capture before presenting the install prompt, not after serving the IPA:
    /// small apps can already be installed when payload delivery completes.
    struct Baseline: Sendable { let app: InstalledApp? }

    static func hasNewInstalledEvidence(baseline: InstalledApp?, current: InstalledApp?,
                                        expectation: InstallConfirmation.Expectation) -> Bool {
        guard let baseline, baseline.bundleIdentifier == expectation.bundleIdentifier,
              let current, current.bundleIdentifier == expectation.bundleIdentifier,
              InstalledState.derive(from: current, expecting: expectation.version) == .installed else { return false }
        if let version = expectation.version, current.version != version { return false }
        if let build = expectation.build, current.build != build { return false }
        if !baseline.isInstalled || baseline.isPlaceholder { return true }
        if let expected = expectation.version, let previous = baseline.version,
           !expected.isEmpty, !previous.isEmpty, previous != expected, current.version == expected { return true }
        if let expected = expectation.build, let previous = baseline.build,
           previous != expected, current.build == expected { return true }
        // iOS can replace the installation container without changing either
        // version string. Both paths must come from positive installed records;
        // a URL by itself, or an unknown baseline, is not installation evidence.
        if let before = installedBundlePath(baseline.bundleURL),
           let after = installedBundlePath(current.bundleURL), before != after { return true }
        return false
    }

    private static func installedBundlePath(_ url: URL?) -> String? {
        guard let url, url.isFileURL, url.pathExtension == "app" else { return nil }
        let path = url.standardizedFileURL.path
        // LaunchServices can expose the same container through either alias.
        return path.hasPrefix("/private/var/") ? String(path.dropFirst(8)) : path
    }
	/// `interval` paces the progress counter. Verification follows `verification`; left nil it
	/// is the standard schedule, or back-to-back checks when `interval` is zero, which is how a
	/// test replays scripted readings without waiting on a clock.
	///
	/// `onVerificationAttempt` is told the number of each device check as it starts, so a
	/// caller can show that verification is still doing something. `now` is the clock every
	/// sample and reading is dated with; it is a parameter so the whole loop can be replayed
	/// against scripted time.
	static func watch(
		_ initial: InstallConfirmation,
		probe: InstalledAppProbing,
        baseline: Baseline? = nil,
		progress: @escaping @Sendable () async -> Double?,
		interval: Duration = .seconds(1),
        startTimeoutEnabled: @escaping @Sendable () async -> Bool = { true },
		onUpdate: @escaping @Sendable (Double?, InstallConfirmation.Phase) async -> Void = { _, _ in },
		verification: InstallVerificationPolicy? = nil,
		onVerificationAttempt: @escaping @Sendable (Int) async -> Void = { _ in },
		now: @escaping @Sendable () -> Date = { Date() }
	) async -> InstallConfirmation.Verdict {
        var confirmation = initial
        var before: InstalledApp?
        if let baseline { before = baseline.app }
        else { before = await probe.installedAppWithTimeout(for: initial.expectation.bundleIdentifier) }

        while !Task.isCancelled {
            let raw = await progress()
            // Positive independent evidence can finish a fast install or update
            // even if the progress counter is unavailable or remains nonzero.
            if confirmation.phase == .waitingForStart || confirmation.phase == .downloading {
                let current = await probe.installedAppWithTimeout(for: initial.expectation.bundleIdentifier)
                // A positively observed placeholder is fresh install activity,
                // even when pre-prompt lookup was restricted. Do not promote a
                // filtered negative/unknown lookup into an "absent" baseline.
                if let current, current.bundleIdentifier == initial.expectation.bundleIdentifier,
                   current.isPlaceholder {
                    before = current
                }
                if hasNewInstalledEvidence(baseline: before, current: current, expectation: initial.expectation) {
                    _ = confirmation.beginVerifying(at: now())
                    let phase = confirmation.record(probe: current, at: now())
                    await onUpdate(raw, phase)
                    if let verdict = phase.verdict { return verdict }
                }
            }
			let phase = confirmation.record(progress: raw, at: now(),
                allowStartTimeout: await startTimeoutEnabled())
			await onUpdate(raw, phase)

			if phase == .verifying {
				// installd has stopped: from here the device's own answer decides.
				return await confirm(
					&confirmation,
					probe: probe,
                    baseline: .init(app: before),
					interval: interval,
					policy: verification,
					onAttempt: onVerificationAttempt,
					onPhase: { phase in await onUpdate(raw, phase) },
					now: now
				)
			}

			if let verdict = phase.verdict {
				return verdict
			}

			await pause(interval)
		}

		return confirmation.cancel().verdict ?? .cancelled
	}

	/// Waits for the device to prove the install, once `confirmation` is verifying.
	///
	/// Every run of checks is bounded three ways. The engine's deadlines end it by time. The
	/// pause between checks grows, so a device that is slow to publish the app is not asked
	/// every second for two minutes. And the number of checks is capped, so the loop still ends
	/// when time cannot be trusted: the engine measures against the device clock, and a clock
	/// set back mid-install would otherwise keep every deadline out of reach.
	static func confirm(
		_ confirmation: inout InstallConfirmation,
		probe: InstalledAppProbing,
        baseline: Baseline? = nil,
		interval: Duration = .seconds(1),
		policy: InstallVerificationPolicy? = nil,
		onAttempt: @escaping @Sendable (Int) async -> Void = { _ in },
		onPhase: @escaping @Sendable (InstallConfirmation.Phase) async -> Void = { _ in },
		now: @escaping @Sendable () -> Date = { Date() }
	) async -> InstallConfirmation.Verdict {
		let policy = policy ?? (interval > .zero ? InstallVerificationPolicy.standard : InstallVerificationPolicy.immediate)
		let identifier = confirmation.expectation.bundleIdentifier
		let maximumAttempts = policy.maximumAttempts(within: confirmation.limits.verify)
		var attempt = 0
        var before = baseline?.app

		while !Task.isCancelled {
			attempt += 1
			await onAttempt(attempt)

			// A slow lookup is given longer on later checks, but never so long that the answer
			// to a deadline is held back behind it.
			let timeout = policy.probeTimeout(
				forAttempt: attempt,
				untilDeadline: confirmation.secondsUntilNextDeadline(at: now())
			)
			let reading = await probe.installedAppWithTimeout(for: identifier, timeout: timeout)
            if let reading, reading.bundleIdentifier == identifier, reading.isPlaceholder {
                before = reading
            }
            var usable = reading
            if baseline != nil, let reading, reading.isInstalled, !reading.isPlaceholder,
               !hasNewInstalledEvidence(baseline: before, current: reading, expectation: confirmation.expectation) {
                // A pre-existing app, even at the same version, does not prove this attempt.
                usable = nil
            }
			var phase = confirmation.record(probe: usable, at: now())
			if phase == .verifying, let maximumAttempts, attempt >= maximumAttempts {
				phase = confirmation.endVerificationUnconfirmed()
			}
			await onPhase(phase)

			if let verdict = phase.verdict {
				return verdict
			}

			let delay = policy.delay(
				afterAttempt: attempt,
				untilDeadline: confirmation.secondsUntilNextDeadline(at: now())
			)
			await pause(.seconds(delay))
		}

		return confirmation.cancel().verdict ?? .cancelled
	}

	private static func pause(_ interval: Duration) async {
		if interval > .zero {
			try? await Task.sleep(for: interval)
		} else {
			await Task.yield()
		}
	}
}
