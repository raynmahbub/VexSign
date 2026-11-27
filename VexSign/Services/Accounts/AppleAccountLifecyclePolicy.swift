// Apple Account lifecycle policy.
//
// The NativeSigning backend already owns authentication, 2FA, certificate and
// profile creation, and the adapter already owns the receipt-bound certificate
// handoff. This file deliberately owns none of those operations. It answers one
// question before a free account is mutated: do the APPLE-OBSERVED inventory
// counts allow this registration, and is the requested renewal path one this
// build is allowed to offer?
//
// The Personal Team numbers below come from Apple's own account help page:
// https://developer.apple.com/help/account/basics/about-your-developer-account/
// "You can register up to 10 App IDs, which expire after 7 days", "up to 3
// devices", and "up to 3 apps per device"; provisionals expire 7 days from
// issuance. Apple remains the issuer and the final authority. A local profile
// journal is NOT a portal inventory and must never authorize a new slot.
//
// Pure Foundation. No Keychain, no network, no clock read except an injected
// date, and no claim that a signed or installed app exists.

import Foundation
import NimbleExtensions

enum AppleAccountKind: String, Equatable, Hashable, Sendable {
    case free
    case paidVerified
    case unverified

    init(_ membership: AppleAccountMembership) {
        switch membership {
        case .free: self = .free
        case .paidVerified: self = .paidVerified
        case .developerProgramUnverified: self = .unverified
        }
    }

    var canProvision: Bool { self != .unverified }

    /// Locally encoded, documented Personal Team ceilings. `nil` means this
    /// policy makes no claim: a paid membership is not a promise of unlimited
    /// portal resources, only that the free-account ceiling is not applied.
    var maximumRegisteredAppIdentifiers: Int? { self == .free ? 10 : nil }
    var maximumRegisteredDevices: Int? { self == .free ? 3 : nil }
    var maximumInstalledAppsPerDevice: Int? { self == .free ? 3 : nil }
    var expectedProfileLifetimeDays: Int? { self == .free ? 7 : nil }
}

/// Where a number came from. Counts must carry their origin so a local journal
/// or a guessed default can never be presented as an Apple portal observation.
enum AppleAccountLimitSource: String, Equatable, Hashable, Sendable {
    case applePersonalTeamDocumentation
    case applePortalPreflight
    case unknown

    var validity: String {
        switch self {
        case .applePersonalTeamDocumentation:
            return .localized("Documented by Apple for a Personal Team. Apple's portal remains authoritative and may change it.")
        case .applePortalPreflight:
            return .localized("Read from Apple's portal during this preflight. It is valid only for that short-lived observation.")
        case .unknown:
            return .localized("Not verified. No quota conclusion may be drawn from this value.")
        }
    }
}

struct AppleAccountLimit: Equatable, Hashable, Sendable {
    let maximum: Int?
    let source: AppleAccountLimitSource

    var validity: String { source.validity }
}

struct AppleAccountLimits: Equatable, Sendable {
    let registeredAppIdentifiers: AppleAccountLimit
    let registeredDevices: AppleAccountLimit
    let installedAppsPerDevice: AppleAccountLimit
    let profileLifetimeDays: AppleAccountLimit
    let documentationURL: String?

    /// Human-readable, source-labelled text for the review screen. It is a
    /// local advisory, not a live portal response or a promise of issuance.
    var appIdentifierSummary: String {
        guard let maximum = registeredAppIdentifiers.maximum else {
            return .localized("No free-account App ID ceiling is applied to this team. Apple may enforce its own limits.")
        }
        return String.localized("Apple documents up to %lld App IDs for a free Personal Team. %@",
                                arguments: maximum, registeredAppIdentifiers.validity)
    }

    var deviceSummary: String {
        guard let maximum = registeredDevices.maximum else {
            return .localized("No free-account device ceiling is applied to this team. Apple may enforce its own limits.")
        }
        return String.localized("Apple documents up to %lld registered devices for a free Personal Team. %@",
                                arguments: maximum, registeredDevices.validity)
    }
}

/// Counts from the read-only SideSign portal preflight. Deliberately does not
/// include `NativeSigningManager.freeAccountAppCount`, which counts local
/// profile receipts and is explicitly labelled "not portal quota" in the UI.
struct AppleAccountPortalObservation: Equatable, Sendable {
    var activeAppIdentifierCount: Int?
    var registeredDeviceCount: Int?
    var source: AppleAccountLimitSource = .applePortalPreflight

    func counted(_ value: Int?) -> Int? {
        guard source == .applePortalPreflight else { return nil }
        return value
    }
}

enum AppleAccountRenewalMode: String, Equatable, Hashable, Sendable {
    /// The user must open the attended refresh flow and approve each stage.
    case attendedManual
    /// No renewal path exists until a verified membership is selected.
    case unavailable

    var detail: String {
        switch self {
        case .attendedManual:
            return .localized("Renewal is an attended, approved flow. VexSign does not renew a profile in the background or by itself.")
        case .unavailable:
            return .localized("No renewal path is available until a verified Apple Account team is selected.")
        }
    }
}

enum AppleAccountLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case unverifiedMembership
    case inventoryUnavailable
    case freeAppIdentifierLimit
    case freeDeviceLimit
    case invalidAppIdentifier
    case invalidCount

    var errorDescription: String? {
        switch self {
        case .unverifiedMembership:
            return .localized("This Apple Account team does not have verified development enrollment. No certificate, device or App ID was changed.")
        case .inventoryUnavailable:
            return .localized("Apple's portal inventory was not observed for this free account. The registration is refused before any portal change; refresh the account and try again.")
        case .freeAppIdentifierLimit:
            return .localized("Apple documents a limit of 10 App IDs for a free Personal Team. This request would exceed it, so no portal change was made.")
        case .freeDeviceLimit:
            return .localized("Apple documents a limit of 3 registered devices for a free Personal Team. This device is not registered and the limit is already reached; no portal change was made.")
        case .invalidAppIdentifier:
            return .localized("The app's bundle identifier is not a valid App ID. No portal change was made.")
        case .invalidCount:
            return .localized("The account inventory returned an impossible count. No portal change was made.")
        }
    }
}

enum AppleAccountProfileLifetime: Equatable, Hashable, Sendable {
    case withinExpected
    case longerThanExpected
    case invalid

    /// An advisory classification, never an authorization to sign or install.
    var isUsableForHandoff: Bool { self != .invalid }
}

enum AppleAccountLifecyclePolicy {
    /// One source-labelled value for the whole app. The URL is documentation,
    /// not a network call and not evidence that this build contacted Apple.
    static func limits(for kind: AppleAccountKind) -> AppleAccountLimits {
        let documented: AppleAccountLimitSource = .applePersonalTeamDocumentation
        let unknown: AppleAccountLimitSource = .unknown
        return AppleAccountLimits(
            registeredAppIdentifiers: .init(maximum: kind.maximumRegisteredAppIdentifiers,
                                            source: kind == .free ? documented : unknown),
            registeredDevices: .init(maximum: kind.maximumRegisteredDevices,
                                     source: kind == .free ? documented : unknown),
            installedAppsPerDevice: .init(maximum: kind.maximumInstalledAppsPerDevice,
                                          source: kind == .free ? documented : unknown),
            profileLifetimeDays: .init(maximum: kind.expectedProfileLifetimeDays,
                                       source: kind == .free ? documented : unknown),
            documentationURL: kind == .free
                ? "https://developer.apple.com/help/account/basics/about-your-developer-account/"
                : nil)
    }

    static func renewalMode(for kind: AppleAccountKind) -> AppleAccountRenewalMode {
        kind.canProvision ? .attendedManual : .unavailable
    }

    /// Fails closed for a new free-account App ID or device registration when
    /// Apple's portal count was not observed. Renewing an app and device already
    /// in the portal inventory does not consume another slot.
    static func requireProvisioning(
        kind: AppleAccountKind,
        observation: AppleAccountPortalObservation,
        requestedAlreadyActive: Bool,
        newAppIdentifierCount: Int,
        requiresDeviceRegistration: Bool
    ) throws {
        guard kind.canProvision else { throw AppleAccountLifecycleError.unverifiedMembership }
        guard newAppIdentifierCount >= 0 else { throw AppleAccountLifecycleError.invalidCount }
        for count in [observation.activeAppIdentifierCount, observation.registeredDeviceCount].compactMap({ $0 }) {
            guard count >= 0, count <= 1000 else { throw AppleAccountLifecycleError.invalidCount }
        }

        let limits = limits(for: kind)
        guard kind == .paidVerified else {
            if requiresDeviceRegistration {
                guard let deviceCount = observation.counted(observation.registeredDeviceCount),
                      let maximum = limits.registeredDevices.maximum else {
                    throw AppleAccountLifecycleError.inventoryUnavailable
                }
                guard deviceCount < maximum else { throw AppleAccountLifecycleError.freeDeviceLimit }
            }
            if newAppIdentifierCount > 0 {
                guard let current = observation.counted(observation.activeAppIdentifierCount),
                      let maximum = limits.registeredAppIdentifiers.maximum else {
                    throw AppleAccountLifecycleError.inventoryUnavailable
                }
                guard current + newAppIdentifierCount <= maximum else {
                    throw AppleAccountLifecycleError.freeAppIdentifierLimit
                }
            } else if !requestedAlreadyActive {
                // Nothing to register and nothing being renewed: there is no
                // plausible provisioning plan. Do not fabricate acceptance.
                throw AppleAccountLifecycleError.invalidAppIdentifier
            }
            return
        }
    }

    /// Classifies the Apple-issued expiry against the kind's expected ceiling.
    /// A longer free profile is reported, not rejected: Apple is the issuer and
    /// a local guess must not invalidate an authentic portal response.
    static func profileLifetime(
        kind: AppleAccountKind,
        expiresAt: Date,
        now: Date
    ) -> AppleAccountProfileLifetime {
        guard expiresAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite,
              expiresAt > now,
              expiresAt.timeIntervalSince(now) <= 5 * 365 * 86_400 else { return .invalid }
        guard let days = kind.expectedProfileLifetimeDays else { return .withinExpected }
        // One day of slack covers clock skew and the way Apple rounds expiry.
        return expiresAt <= now.addingTimeInterval(TimeInterval(days + 1) * 86_400)
            ? .withinExpected : .longerThanExpected
    }
}
