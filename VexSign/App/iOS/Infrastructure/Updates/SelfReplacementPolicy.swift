//
//  SelfReplacementPolicy.swift
//  VexSign
//
//  In-place update of the running app, from a copy the user already signed here.
//
//  Two remote self-update routes are refused on purpose and stay refused: uploading the signing
//  key to an updater, and driving an unverified paired-device mutation. Neither is needed to
//  update VexSign, because the app can do what it does for any other app — sign the release with
//  the certificate already in the store, serve it from its own local HTTPS server and hand the
//  `.itms-services` URL to iOS, which replaces the bundle in place. The key never leaves the
//  device and nothing is claimed about the result until iOS reports it.
//
//  What that route does require is stated as one question here, apart from the UI and apart from
//  the installer, so it can be tested without a device: is the copy in the library a signed,
//  newer build of *this* app?
//

import Foundation
import NimbleExtensions

/// What stands between the library copy and an in-place update.
///
/// `rawValue` is logged; `message` is what the update sheet shows, and both name the next step
/// rather than only the refusal.
enum SelfReplacementBlocker: String, Equatable {
    /// Nothing in the library is the running app.
    case missing
    /// The copy is an imported (unsigned) build.
    case notSigned
    /// Same version or older: installing it would be a downgrade, which iOS refuses anyway.
    case notNewer
    /// A signed copy exists, but it belongs to another app.
    case differentApp

    var message: String {
        switch self {
        case .missing:
            return .localized("No signed copy of VexSign is in Library yet. Download the release IPA, import it, sign it with the certificate you installed VexSign with, then come back here to install it in place.")
        case .notSigned:
            return .localized("The copy of VexSign in Library is not signed. Sign it with the certificate you installed VexSign with, then install it from here.")
        case .notNewer:
            return .localized("The signed copy of VexSign in Library is not newer than the build that is running. iOS only replaces a bundle with a higher version.")
        case .differentApp:
            return .localized("The signed copy in Library is a different app. An in-place update has to carry VexSign's bundle identifier.")
        }
    }
}

/// One candidate library copy, reduced to the facts the decision needs.
struct SelfReplacementCandidate: Equatable {
    let identifier: String?
    let version: String?
    let isSigned: Bool
}

/// The one rule an in-place update has to pass.
///
/// A `nil` verdict means iOS may be handed the copy. Anything else is the reason it may not, and
/// the caller is expected to show it instead of starting an install that iOS would reject.
enum SelfReplacementPolicy {
    static func verdict(
        candidate: SelfReplacementCandidate,
        runningIdentifier: String?,
        runningVersion: String
    ) -> SelfReplacementBlocker? {
        // Both identifiers are required: an unidentified copy cannot be proven to be this app,
        // and a build with no bundle identifier has nothing to replace.
        guard let runningIdentifier, !runningIdentifier.isEmpty,
              let candidateIdentifier = candidate.identifier,
              candidateIdentifier == runningIdentifier
        else { return .differentApp }

        guard candidate.isSigned else { return .notSigned }

        // No version is treated as unusable rather than as "assume newer": the gamble would be
        // resolved by iOS showing an error after the transfer.
        guard let version = candidate.version, !version.isEmpty else { return .notNewer }
        // A token submitted for an update is not proof of anything, so the comparison is the same
        // one the update check uses, including prerelease ordering.
        guard SelfUpdateManager.compare(version, runningVersion) == .orderedDescending else {
            return .notNewer
        }
        return nil
    }

    /// The first copy in `candidates` that may replace the running app, plus the reason nothing
    /// qualified when there is such a copy to explain.
    ///
    /// Order is preserved: the caller reads the library in its own order so the choice is stable
    /// between two runs over the same data.
    static func select(
        from candidates: [SelfReplacementCandidate],
        runningIdentifier: String?,
        runningVersion: String
    ) -> (selected: SelfReplacementCandidate?, blocker: SelfReplacementBlocker?) {
        guard let runningIdentifier, !runningIdentifier.isEmpty else { return (nil, .differentApp) }

        var firstBlocker: SelfReplacementBlocker?
        for candidate in candidates {
            let verdict = verdict(
                candidate: candidate,
                runningIdentifier: runningIdentifier,
                runningVersion: runningVersion
            )
            if verdict == nil { return (candidate, nil) }
            // `.differentApp` says the least about *this* app's copies, so it never wins the
            // explanation when a real candidate was seen.
            if firstBlocker == nil || (firstBlocker == .differentApp && verdict != .differentApp) {
                firstBlocker = verdict
            }
        }
        return (nil, firstBlocker ?? .missing)
    }
}
