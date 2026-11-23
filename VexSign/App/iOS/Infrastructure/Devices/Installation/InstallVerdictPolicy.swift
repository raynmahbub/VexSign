//
//  InstallVerdictPolicy.swift
//  VexSign
//
//  What a device verdict means for the attempt that produced it.
//
//  `AppInstaller._finishConfirmed` carried this mapping inline, next to the task cancellation, the
//  progress reset and the log line — so the one rule a reviewer actually wants to check ("does
//  another version count as installed?") was only readable by following a switch inside an
//  installer. The rule is a pure function of the verdict; the side effects stay where they were.
//

import Foundation

/// What the attempt reports after the device answered.
enum InstallVerdictOutcome: Equatable {
    /// The device reports the app at the version that was sent.
    case confirmed
    /// The user or the caller called it off.
    case cancelled
    /// The app is installed at another version: proof of presence, not of this artifact.
    case anotherVersion
    /// No evidence either way by the deadline.
    case notConfirmed
}

enum InstallVerdictPolicy {
    /// The outcome for a verdict, with no side effects and no defaults to fall through.
    ///
    /// `installedOtherVersion` is deliberately not `confirmed`: installing the same bundle from an
    /// older copy would otherwise be reported as success. `notInstalled`, `timedOutWaiting` and
    /// `timedOutVerifying` are one group because they share the only honest answer — this attempt
    /// left no proof — and treating them differently is how a filtered probe negative becomes a
    /// failure message about the user's device.
    static func outcome(for verdict: InstallConfirmation.Verdict) -> InstallVerdictOutcome {
        switch verdict {
        case .installed:
            return .confirmed
        case .cancelled:
            return .cancelled
        case .installedOtherVersion:
            return .anotherVersion
        case .notInstalled, .timedOutWaiting, .timedOutVerifying:
            return .notConfirmed
        }
    }
}
