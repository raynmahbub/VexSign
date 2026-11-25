//
//  AccountRefreshFlow.swift
//  VexSign
//
//  The manual Apple Account refresh contract: renew provisioning, import the exact
//  identity it produced, re-sign the retained copy with that identity, hand the
//  result to the delivery route the user chose, and only then look for evidence.
//
//  Nothing here signs, installs, talks to Apple or reads the library. Values cross
//  those boundaries; the orchestrator in `ManualAccountRefreshCoordinator` calls
//  injected steps and records what each one reported.
//

import Foundation

enum AccountRefreshStage: String, Codable, CaseIterable, Sendable {
    case preflight
    case provision
    case importIdentity
    case sign
    case install
    case verify
}

/// What the flow must hold constant across all six stages.
struct AccountRefreshRequest: Equatable, Sendable {
    let correlationID: UUID
    let app: LibraryAppReference
    let deviceIdentifier: String
    let bundleIdentifier: String
    let teamIdentifier: String
    /// The identity the installed copy already uses. A different identity on the
    /// renewed profile ends the flow: it may not install over the existing copy.
    let certificateUUID: String
    let profileUUID: UUID
    /// The expiry recorded in the profile being replaced.
    let baselineExpiry: Date
}

struct AccountRefreshReceipt: Equatable, Sendable {
    let profileUUID: UUID
    let expiresAt: Date
}

struct AccountRefreshHandoff: Equatable, Sendable {
    let certificateUUID: String
    let profileUUID: UUID
    let bundleIdentifier: String
    let expiresAt: Date
}

struct AccountRefreshSignedArtifact: Equatable, Sendable {
    let artifactID: String
    let certificateUUID: String
    let bundleIdentifier: String
}

struct AccountRefreshInstallation: Equatable, Sendable {
    let artifactID: String
    let bundleIdentifier: String
    /// A submitted package, not an installed app. A false value stops the flow before
    /// verification so a rejected handoff cannot be reported as a completed refresh.
    let submitted: Bool
}

enum AccountRefreshVerification: Equatable, Sendable {
    case confirmed(bundleIdentifier: String, installedVersion: String?)
    /// No supported exact device reading. The refresh is recorded as unverified;
    /// the user is told to check the Home Screen, never that the install succeeded.
    case unconfirmed
}

struct AccountRefreshResult: Equatable, Sendable {
    let correlationID: UUID
    let certificateUUID: String
    let profileUUID: UUID
    let expiresAt: Date
    let signedArtifactID: String
    let verification: AccountRefreshVerification

    var isVerified: Bool {
        if case .confirmed = verification { return true }
        return false
    }
}

enum AccountRefreshError: LocalizedError, Equatable, Sendable {
    case invalidInput
    case cancelled
    case identityChanged(expected: String, actual: String)
    case profileChanged(expected: UUID, actual: UUID)
    case appChanged
    case expiryNotAdvanced
    case expired
    case stageFailed(AccountRefreshStage, String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "This refresh needs a signed library copy, a device, an app identifier and the identity it was signed with."
        case .cancelled:
            return "The refresh was stopped. No later stage was started."
        case .identityChanged:
            return "The renewed profile uses a different signing identity. Nothing was re-signed or installed."
        case .profileChanged:
            return "The imported profile is not the one Apple just returned. Nothing was re-signed or installed."
        case .appChanged:
            return "The app or its bundle identifier changed during the refresh. Nothing was re-signed or installed."
        case .expiryNotAdvanced:
            return "Apple returned a profile with the same or an earlier expiry. Nothing was imported or installed."
        case .expired:
            return "The renewed profile is already expired. Nothing was imported or installed."
        case .stageFailed(let stage, _):
            return "The \(stage.title) stage could not finish. No later stage was started."
        }
    }
}

extension AccountRefreshStage {
    var title: String {
        switch self {
        case .preflight: return "preflight"
        case .provision: return "provisioning"
        case .importIdentity: return "identity import"
        case .sign: return "signing"
        case .install: return "installation handoff"
        case .verify: return "verification"
        }
    }
}

/// Checks that one stage's output is still the operation the user started.
enum AccountRefreshPlanner {
    static func validatePreflight(_ request: AccountRefreshRequest, now: Date) throws {
        guard request.app.isSigned,
              !request.deviceIdentifier.isEmpty,
              !request.bundleIdentifier.isEmpty,
              !request.teamIdentifier.isEmpty,
              !request.certificateUUID.isEmpty,
              request.correlationID.uuidString != UUID.null.uuidString,
              request.baselineExpiry.timeIntervalSince1970.isFinite else {
            throw AccountRefreshError.invalidInput
        }
        _ = now
    }

    static func validateProvision(_ receipt: AccountRefreshReceipt, against request: AccountRefreshRequest, now: Date) throws {
        guard receipt.expiryNotAdvancedCheck(now: now) else { throw AccountRefreshError.expired }
        guard receipt.expiresAt > request.baselineExpiry else { throw AccountRefreshError.expiryNotAdvanced }
        guard receipt.expiresAt.timeIntervalSince1970.isFinite else { throw AccountRefreshError.invalidInput }
    }

    static func validateHandoff(
        _ handoff: AccountRefreshHandoff,
        against request: AccountRefreshRequest,
        receipt: AccountRefreshReceipt,
        now: Date
    ) throws {
        guard handoff.certificateUUID.caseInsensitiveCompare(request.certificateUUID) == .orderedSame else {
            throw AccountRefreshError.identityChanged(expected: request.certificateUUID, actual: handoff.certificateUUID)
        }
        guard handoff.profileUUID == receipt.profileUUID else {
            throw AccountRefreshError.profileChanged(expected: receipt.profileUUID, actual: handoff.profileUUID)
        }
        guard handoff.bundleIdentifier == request.bundleIdentifier else { throw AccountRefreshError.appChanged }
        guard handoff.expiresAt == receipt.expiresAt, handoff.expiresAt > now else { throw AccountRefreshError.expired }
    }

    static func validateSign(_ artifact: AccountRefreshSignedArtifact, handoff: AccountRefreshHandoff) throws {
        guard !artifact.artifactID.isEmpty,
              artifact.certificateUUID.caseInsensitiveCompare(handoff.certificateUUID) == .orderedSame,
              artifact.bundleIdentifier == handoff.bundleIdentifier else {
            throw AccountRefreshError.identityChanged(expected: handoff.certificateUUID, actual: artifact.certificateUUID)
        }
    }

    static func validateInstallation(_ installation: AccountRefreshInstallation, artifact: AccountRefreshSignedArtifact) throws {
        guard installation.submitted,
              installation.artifactID == artifact.artifactID,
              installation.bundleIdentifier == artifact.bundleIdentifier else {
            throw AccountRefreshError.appChanged
        }
    }

    static func validateVerification(_ verification: AccountRefreshVerification, request: AccountRefreshRequest) throws {
        guard case .confirmed(let identifier, _) = verification else { return }
        guard identifier == request.bundleIdentifier else { throw AccountRefreshError.appChanged }
    }
}

private extension AccountRefreshReceipt {
    func expiryNotAdvancedCheck(now: Date) -> Bool {
        expiresAt.timeIntervalSince1970.isFinite && expiresAt > now
    }
}

private extension UUID {
    static var null: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID() }
}
