//
//  IdentityDeliveryPolicy.swift
//  VexSign
//
//  Who signs an app and where the signed app goes are two different decisions.
//
//  An Apple Account, an imported `.p12` pair and a managed certificate all produce
//  installable output. None of them names a destination. In particular, a free Apple
//  Account must not turn into a guest-container install merely because the host
//  runtime is present on this device: the guest route is a separate, explicit choice.
//
//  Pure and Foundation-only so routing, presentation and tests share one rule.
//

import Foundation

/// Where the signing material came from. This is not a capability claim and not a
/// statement about what the device can do.
enum SigningIdentitySource: String, Codable, CaseIterable, Sendable {
    case appleAccount
    case importedCertificate
    case managed
}

/// The destination a signed package can be handed to.
enum DeliveryRoute: String, Codable, CaseIterable, Sendable {
    /// This device's own installer over a local HTTP manifest.
    case directServer
    /// A paired device installer.
    case directPaired
    /// An explicitly selected guest import in a container host.
    case guestContainer
}

/// The one automatic-delivery decision this app may make.
///
/// A case here is an inference, never a user choice. Returning `.direct` means the
/// caller keeps its established direct transport; it does not mean the app was
/// installed or that a certificate was valid.
enum AutomaticDeliveryDecision: Equatable, Sendable {
    case direct
    case guest
}

enum IdentityDeliveryPolicy {
    /// The guest route always needs an explicit selection, whatever the identity.
    /// The stored guest method is such a selection: it was made by the user in an
    /// earlier session, not inferred from the account now signing in.
    static func decide(
        identity: SigningIdentitySource,
        hasDirectPaidCandidate: Bool,
        storedGuestSelection: Bool,
        hasGuestRuntime: Bool
    ) -> AutomaticDeliveryDecision {
        if storedGuestSelection { return .guest }
        // The remaining inputs are deliberately unused: a paid candidate changes
        // which certificate signs, not where the package goes; an identity and a
        // guest runtime are not delivery choices either. Keeping them in the
        // signature documents what must not influence the answer.
        _ = identity
        _ = hasDirectPaidCandidate
        _ = hasGuestRuntime
        return .direct
    }

    /// Whether selecting this identity may by itself change the user's delivery method.
    /// The answer is no for every identity, including an Apple Account.
    static func selectionChangesDelivery(identity: SigningIdentitySource) -> Bool { false }
}

/// The two choices the setup screen offers. They are deliberately separate values:
/// changing one must not write the other, and neither is a device capability claim.
enum SigningIdentityChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleAccount
    case importedCertificate

    var id: String { rawValue }

    var source: SigningIdentitySource {
        switch self {
        case .appleAccount: return .appleAccount
        case .importedCertificate: return .importedCertificate
        }
    }
}

/// The destination choice. The direct route keeps whichever direct transport the
/// user selected (server or paired); the container route is a guest import in the
/// embedded host and is never implied by an identity.
enum InstallationMethodChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct
    case embeddedContainer

    var id: String { rawValue }
}

struct InstallationMethodReadiness: Equatable, Sendable {
    var directAvailable: Bool
    var containerAvailable: Bool
}

enum InstallationMethodSelection {
    case usable(InstallationMethodChoice)
    /// The selection is explicit but the prerequisite is absent. Routing fails closed;
    /// it must not quietly fall back to the other method.
    case blocked(InstallationMethodChoice)

    var choice: InstallationMethodChoice {
        switch self {
        case .usable(let choice), .blocked(let choice): return choice
        }
    }

    var isUsable: Bool {
        if case .usable = self { return true }
        return false
    }
}

enum InstallationMethodPolicy {
    /// Readiness gates availability; identity has no vote. Selecting an Apple Account
    /// can therefore never turn into a container install, and a container that is not
    /// loaded is reported as blocked rather than replaced with a direct route.
    static func resolve(
        choice: InstallationMethodChoice,
        readiness: InstallationMethodReadiness
    ) -> InstallationMethodSelection {
        switch choice {
        case .direct:
            return readiness.directAvailable ? .usable(.direct) : .blocked(.direct)
        case .embeddedContainer:
            return readiness.containerAvailable ? .usable(.embeddedContainer) : .blocked(.embeddedContainer)
        }
    }

    /// Identity changes are always delivery-neutral, in both directions.
    static func changingIdentityPreservesDelivery(source: SigningIdentitySource) -> Bool { true }
}
