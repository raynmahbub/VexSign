//
//  AutomationAvailability.swift
//  VexSign
//
//  Why an automation pass did not run, and what a finished pass may claim.
//
//  `BackgroundAutomation.run` returns nil for five different reasons — turned off, already
//  running, Game Mode, Update All running, cancelled — and records each one in
//  `AutomationHistoryStore`. The Shortcut did not read any of it: `UpdateAllIntent` treated
//  nil as "found nothing" and told the user *"Everything is up to date."* That sentence is
//  true of a pass that compared every source, and false for a pass that never started.
//
//  The same shape produced a second problem: a run that found updates but failed to sign
//  some of them reported only the successes, so a shortcut log could not tell "signed 2"
//  from "signed 2, failed 3".
//
//  Both answers are pure functions of values the caller already has, so they live here and
//  are tested without a run, a source or a certificate.
//

import Foundation
import NimbleExtensions

// MARK: - Availability

/// The conditions that stop an automation pass before it starts.
enum AutomationAvailability {
    enum Blocker: String, Equatable, CaseIterable {
        /// The user has not enabled automation.
        case disabled
        /// A pass is already running (this one or Update All).
        case busy
        /// Game Mode pauses update traffic.
        case gameMode
    }

    /// The first blocker that applies, in the order `run` checks them.
    ///
    /// Order matters: a pass that is both disabled and busy reports "disabled", because
    /// turning automation on is the action the user would have to take.
    static func blocker(
        enabled: Bool,
        running: Bool,
        gameMode: Bool,
        updateAllRunning: Bool
    ) -> Blocker? {
        if !enabled { return .disabled }
        if running || updateAllRunning { return .busy }
        if gameMode { return .gameMode }
        return nil
    }

    /// What to tell the user. Never a success claim.
    static func message(for blocker: Blocker) -> String {
        switch blocker {
        case .disabled:
            return .localized("Automation is turned off. Turn it on in Settings → Automation before running this from Shortcuts.")
        case .busy:
            return .localized("Another automation pass is already running. Nothing was started twice.")
        case .gameMode:
            return .localized("Game Mode is on, so update checks are paused. Turn Game Mode off to run this.")
        }
    }
}

// MARK: - Dialogue

/// What a Shortcut says about a pass: finished, blocked, or not run.
enum AutomationDialogue {
    /// The sentence for a finished pass.
    ///
    /// - Parameters:
    ///   - found: updates the pass discovered.
    ///   - signed: apps it signed and queued.
    ///   - failed: operations it could not complete.
    ///   - blocked: set when the pass never started.
    static func message(found: Int, signed: Int, failed: Int = 0, blocked: AutomationAvailability.Blocker? = nil) -> String {
        if let blocked { return AutomationAvailability.message(for: blocked) }

        var sentence: String
        if found == 0 && failed == 0 {
            sentence = .localized("Everything is up to date.")
        } else if found == 0 {
            // Nothing was compared, so "up to date" would be a claim this pass cannot make.
            sentence = .localized("%lld operations could not be completed.", arguments: failed)
        } else if signed == 0 {
            sentence = .localized("%lld updates found. Enable “Sign & queue” in Settings → Automation to sign them automatically.", arguments: found)
        } else {
            sentence = .localized("%lld apps signed and queued for install.", arguments: signed)
        }

        // Failures are reported next to the count they belong to, never instead of it.
        if found > 0 && failed > 0 {
            sentence += " " + String.localized("%lld operations could not be completed.", arguments: failed)
        }
        return sentence
    }

    /// The sentence when the pass returned no result and no blocker explained it.
    ///
    /// This is the cancellation and race path: `run` may return nil after its guards pass.
    /// Saying nothing changed is the only honest report — the pass may have refreshed sources
    /// and been stopped before signing anything.
    static var unfinished: String {
        .localized("The automation pass did not finish, so nothing is reported as updated. Open VexSign to see what it did.")
    }
}
