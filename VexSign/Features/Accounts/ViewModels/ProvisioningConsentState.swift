//
//  ProvisioningConsentState.swift
//  VexSign
//
//  The approvals the provisioning flow collects, as one value instead of six
//  `@State` booleans split across two view files.
//
//  The rule that decided whether "Start Provisioning" may run lived inside a
//  `.disabled(…)` expression the tests could not reach, and the screen offered no
//  explanation when it was disabled: a user who had not signed in saw a wizard of
//  greyed-out buttons and concluded the feature was broken. As a value the table
//  is testable, the reset after an account change is one call, and the sentence
//  that explains a disabled button comes from the same type.
//

import Foundation
import NimbleExtensions

struct ProvisioningConsentState: Equatable {
    /// One development certificate may be created if no owned certificate exists.
    var certificate = false
    /// The device and App ID may be registered.
    var registration = false
    /// A profile may be created for this exact app, device and owned identity.
    var profile = false
    /// A regeneration of this app's existing Apple profile may be requested.
    var regeneration = false
    /// A later profile may be stored before the signing handoff.
    var keyExport = false
    /// The profile must outlive the signed library copy. Renewal mode starts with
    /// this on, because that is the whole point of a renewal.
    var laterProfile: Bool

    init(cellularReview: Bool = false) {
        laterProfile = cellularReview
    }

    /// What `AppleAccountProvisioningApproval` needs, derived rather than copied.
    var approval: AppleAccountProvisioningApproval {
        AppleAccountProvisioningApproval(
            certificate: certificate,
            registration: registration,
            profile: profile
        )
    }

    /// Every approval the portal call needs has been given.
    var isComplete: Bool { certificate && registration && profile }

    /// Clears the approvals that authorize a mutation of the Apple account.
    ///
    /// `laterProfile` deliberately survives: it describes the app being renewed,
    /// not this submission, and switching accounts already resets it by replacing
    /// the whole value.
    mutating func reset() {
        certificate = false
        registration = false
        profile = false
        regeneration = false
        keyExport = false
    }

    /// Why the primary action cannot run yet, or `nil` when it can.
    ///
    /// The order matters: it is the order the screen reveals the preconditions, so
    /// the sentence names the first thing the user has to do rather than the last
    /// checkbox they ticked.
    func blockedReason(hasSession: Bool, hasApp: Bool, isProvisioning: Bool) -> String? {
        if !hasSession {
            return .localized("Sign in under Settings → Signing Methods, then choose the app to provision.")
        }
        if !hasApp {
            return .localized("Choose the app this profile is for.")
        }
        if isProvisioning {
            return .localized("Provisioning is already running. Wait for it to finish or cancel it first.")
        }
        if !isComplete {
            return .localized("Approve the certificate, the device registration and the profile to start.")
        }
        return nil
    }
}
