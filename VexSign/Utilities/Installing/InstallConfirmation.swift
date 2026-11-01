//
//  InstallConfirmation.swift
//  VexSign
//
//  Decides when an install is really finished, and on what evidence (see docs/AUDIT_2026-10-31.md).
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
		/// How long the prompt may sit unanswered before nothing is going to happen.
		var start: TimeInterval = 120
		/// How long the device gets to finish writing the app after progress ends.
		var verify: TimeInterval = 600
		/// How long the device gets to show the app, or to report the new version.
		var settle: TimeInterval = 20
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
		/// iOS rolled the install back: the app is not on the device.
		case notInstalled
		/// The prompt was never answered. Nothing was installed.
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

	private var _waitingSince: Date?
	private var _verifyingAt: Date?

	init(expectation: Expectation, limits: Limits = Limits()) {
		self.expectation = expectation
		self.limits = limits
	}

	// MARK: Progress

	/// Feeds one progress sample. `nil` means the device could not read the counter at all.
	mutating func record(progress: Double?, at date: Date) -> Phase {
		guard !phase.isFinished else { return phase }

		if (progress ?? 0) > 0 {
			if phase == .waitingForStart { phase = .downloading }
			return phase
		}

		switch phase {
		case .waitingForStart:
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

		switch InstalledState.derive(from: probe, expecting: expectation.version) {
		case .installed:
			return _finish(.installed)

		case .installedOtherVersion(let version):
			// The version string can lag the install by a moment; only call it different once it
			// has had the settle window to catch up.
			return settled ? _finish(.installedOtherVersion(version)) : phase

		case .notInstalled:
			return settled ? _finish(.notInstalled) : phase

		case .unknown:
			break
		}

		if date.timeIntervalSince(verifyStart) >= limits.verify {
			return _finish(.timedOutVerifying)
		}

		return phase
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

// MARK: - Verdict text

extension InstallConfirmation.Verdict {
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
			.localized("iOS did not keep the app. The install was rolled back — usually a signing certificate or provisioning profile the device rejects. Sign again with a valid certificate and retry.")
		case .timedOutWaiting:
			.localized("The install never started. iOS may not have shown its prompt — retry and keep VexSign in the foreground.")
		case .timedOutVerifying:
			.localized("iOS stopped reporting progress and the app never appeared on the device. Retry, or switch the installation method in Settings → Installation.")
		}
	}
}

// MARK: - Watcher

/// Polls install progress, then the device, and reports what actually happened.
///
/// Both install paths feed the same engine through this loop, so there is one rule for what
/// "installed" means. The I/O is injected, which is also what makes it testable.
enum InstallWatcher {
	static func watch(
		_ initial: InstallConfirmation,
		probe: InstalledAppProbing,
		progress: @escaping @Sendable () async -> Double?,
		interval: Duration = .milliseconds(250),
		onUpdate: @escaping @Sendable (Double?, InstallConfirmation.Phase) async -> Void = { _, _ in }
	) async -> InstallConfirmation.Verdict {
		var confirmation = initial

		while !Task.isCancelled {
			let raw = await progress()
			let phase = confirmation.record(progress: raw, at: Date())
			await onUpdate(raw, phase)

			if phase == .verifying {
				// installd has stopped: from here the device's own answer decides.
				return await confirm(&confirmation, probe: probe, interval: interval) { phase in
					await onUpdate(raw, phase)
				}
			}

			if let verdict = phase.verdict {
				return verdict
			}

			await pause(interval)
		}

		return confirmation.cancel().verdict ?? .cancelled
	}

	/// Waits for the device to prove the install, once `confirmation` is verifying.
	static func confirm(
		_ confirmation: inout InstallConfirmation,
		probe: InstalledAppProbing,
		interval: Duration = .milliseconds(250),
		onPhase: @escaping @Sendable (InstallConfirmation.Phase) async -> Void = { _ in }
	) async -> InstallConfirmation.Verdict {
		while !Task.isCancelled {
			let phase = confirmation.record(
				probe: probe.installedApp(for: confirmation.expectation.bundleIdentifier),
				at: Date()
			)
			await onPhase(phase)

			if let verdict = phase.verdict {
				return verdict
			}

			await pause(interval)
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
