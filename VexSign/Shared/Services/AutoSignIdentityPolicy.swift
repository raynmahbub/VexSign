//
//  AutoSignIdentityPolicy.swift
//  VexSign
//
//  Unattended signing must use the identity the user selected. An Apple Account
//  needs provisioning, key-export and device approvals that no import pipeline,
//  web upload or Shortcut may supply, so those paths stop with an honest review
//  requirement instead of silently signing with a stored `.p12`.
//

import Foundation

enum AutoSignIdentityDecision: Equatable, Sendable {
    case allow
    case requireAttendedReview
}

enum AutoSignIdentityPolicy {
    /// `attendedAppleAccountRefresh` is true only for the reviewed refresh screen,
    /// which imports the exact identity Apple returned in the same run.
    static func decide(
        identity: SigningIdentityChoice,
        attendedAppleAccountRefresh: Bool = false
    ) -> AutoSignIdentityDecision {
        if identity == .appleAccount, !attendedAppleAccountRefresh {
            return .requireAttendedReview
        }
        return .allow
    }
}
