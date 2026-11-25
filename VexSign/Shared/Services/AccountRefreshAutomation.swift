//
//  AccountRefreshAutomation.swift
//  VexSign
//
//  What an unattended pass may do about an expiring Apple Account profile.
//
//  A Shortcut can open the manual review. A background pass cannot collect an
//  account password, a two-factor code or the separate key-export consent, so it
//  never starts a refresh: it only reminds. The preference is off by default and
//  the decision is pure, so neither a toggle nor a notification can imply that
//  provisioning happened.
//

import Foundation

enum AccountRefreshReminderReason: String, Codable, CaseIterable, Sendable {
    case sessionNeedsAuthentication
    case approvalRequired
}

enum AccountRefreshAutomationDecision: Equatable, Sendable {
    case skip
    /// Open the foreground review; the user supplies every approval there.
    case openReview
    case remind(AccountRefreshReminderReason)

    var reason: AccountRefreshReminderReason? {
        if case .remind(let reason) = self { return reason }
        return nil
    }
}

enum AccountRefreshAutomationPolicy {
    static func decide(
        isEnabled: Bool,
        hasDueRefresh: Bool,
        sessionReady: Bool,
        fromBackground: Bool
    ) -> AccountRefreshAutomationDecision {
        guard isEnabled, hasDueRefresh else { return .skip }
        if !fromBackground { return .openReview }
        guard sessionReady else { return .remind(.sessionNeedsAuthentication) }
        return .remind(.approvalRequired)
    }
}
