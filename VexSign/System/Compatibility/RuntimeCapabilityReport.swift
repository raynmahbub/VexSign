//
//  RuntimeCapabilityReport.swift
//  VexSign
//
//  What this build can do with an embedded runtime, in one place.
//
//  The answers already existed as three independent booleans — `isGuestBuild`,
//  `isPrimaryHost` and `VEXEmbeddedRuntimeAvailable()` — read from whichever view needed
//  one of them. A diagnostics export could not say which execution layout the user was
//  running, and "guest keychain hooks are off in this build" was nowhere written down:
//  it was knowledge held in a prose guide; the report is the maintained form.
//
//  This type does not add state. It derives a report from those same flags plus the
//  injected facts a test can supply, and it is the single place that answers "can this
//  build do X". `EmbeddedContainerRuntime.supportsScheduledGuestTasks` now reads it, so
//  the boolean and the report cannot disagree.
//
//  Nothing here is a promise about the host: `available` means this build reaches the
//  host entry point, not that the host accepted, ran, or signed anything. Execution
//  evidence lives in `ContainerGuestState`, which distinguishes `unknown` from
//  `imported` for exactly that reason.
//

import Foundation
import NimbleExtensions

// MARK: - Report

/// The runtime operations this build can reach, and the honest reason for each it cannot.
struct RuntimeCapabilityReport: Equatable {
    // MARK: Environment

    /// Which execution layout this process is running in.
    ///
    /// `standalone` is the ordinary app: the embedded runtime is a separate combined build
    /// (`Services/Integrations/build.py`), so an ordinary install reaches none of these
    /// operations and must not show a runtime control that cannot work.
    enum Environment: String, Equatable, CaseIterable {
        case standalone
        case combinedNativePrimary
        case combinedGuestPrototype
        /// A combined package whose flags are missing or contradictory. Reported as its own
        /// case rather than guessed into one of the two real layouts.
        case combinedUnidentified
    }

    /// A runtime operation, named after what it does rather than where it is called from.
    enum Operation: String, Equatable, CaseIterable {
        /// Open the embedded container's own UI.
        case embeddedContainerUI
        /// Open the embedded SideStore session.
        case embeddedSideStoreSession
        /// Copy a prepared IPA into the host inbox for the container to import.
        case guestImportStaging
        /// Ask the host to switch sessions. This restarts the host process.
        case sessionSwitch
        /// Guest keychain isolation hooks. Only the guest prototype installs these; the
        /// native-primary layout deliberately keeps the host application identity.
        case guestKeychainHooks
        /// Background tasks registered by this build. Available in the ordinary app and in
        /// the native-primary layout; the guest prototype cannot register the handlers.
        case scheduledGuestTasks
        /// Handoff to a separately installed runtime application. Never available: VexSign
        /// reaches the runtime it was built with, and a detected URL handler is not evidence
        /// that an external container would accept an import.
        case externalAppHandoff
    }

    /// Why an operation is not reachable from this build.
    enum Reason: String, Equatable {
        /// The ordinary app: the embedded runtime is a different build.
        case runtimeNotLoaded
        /// A combined build whose host is loaded but incomplete: an older fork, or
        /// one built before this version's entry points existed. Distinct from
        /// `runtimeNotLoaded`, because the fix is a matching host, not a reinstall
        /// of the same app.
        case hostIncomplete
        /// The host is present but this layout never installs the relevant hooks.
        case notPartOfThisLayout
        /// The operation restarts the host process, which the caller has to consent to.
        case restartsHost
        /// VexSign does not implement this and cannot: see `externalAppHandoff`.
        case unsupportedByDesign
    }

    enum Availability: Equatable {
        case available
        case unavailable(Reason)

        var isAvailable: Bool { self == .available }
    }

    // MARK: Facts

    /// Everything the report depends on. Injectable so the matrix can be tested without a
    /// bundle, a host process or a device.
    struct Facts: Equatable {
        var isGuestBuild: Bool
        var isPrimaryHost: Bool
        var runtimeLoaded: Bool
        /// Host entry points the loaded host does not answer. Empty for an
        /// ordinary install and for a host that implements the whole contract.
        var missingHostSelectors: [String]

        init(
            isGuestBuild: Bool,
            isPrimaryHost: Bool,
            runtimeLoaded: Bool,
            missingHostSelectors: [String] = []
        ) {
            self.isGuestBuild = isGuestBuild
            self.isPrimaryHost = isPrimaryHost
            self.runtimeLoaded = runtimeLoaded
            self.missingHostSelectors = missingHostSelectors
        }
    }

    // MARK: Shape

    let environment: Environment
    let availability: [Operation: Availability]

    func isAvailable(_ operation: Operation) -> Bool {
        availability[operation]?.isAvailable ?? false
    }

    func reason(for operation: Operation) -> Reason? {
        guard case let .unavailable(reason) = availability[operation] else { return nil }
        return reason
    }

    // MARK: Derivation

    static func make(_ facts: Facts) -> RuntimeCapabilityReport {
        let environment = self.environment(for: facts)
        // Named `resolved`, not `availability`: a local of that name shadows the static
        // `availability(of:in:facts:)` below and the call stops resolving.
        var resolved: [Operation: Availability] = [:]
        for operation in Operation.allCases {
            resolved[operation] = availability(of: operation, in: environment, facts: facts)
        }
        return RuntimeCapabilityReport(environment: environment, availability: resolved)
    }

    static func environment(for facts: Facts) -> Environment {
        // The guest flag wins: a package that claims both is the guest layout, because that
        // layout replaces the entry point entirely and the primary flag is then decorative.
        if facts.isGuestBuild { return .combinedGuestPrototype }
        if facts.isPrimaryHost { return .combinedNativePrimary }
        if facts.runtimeLoaded { return .combinedUnidentified }
        return .standalone
    }

    private static func availability(
        of operation: Operation,
        in environment: Environment,
        facts: Facts
    ) -> Availability {
        // Reachability of the host entry point gates everything except the one operation
        // VexSign does not implement at all.
        guard operation != .externalAppHandoff else { return .unavailable(.unsupportedByDesign) }
        // Background tasks belong to this app, not to the embedded runtime, so they do not
        // depend on the runtime being loaded. Only the guest prototype loses them, because
        // its entry point is not the one that registers the handlers. Gating this on the
        // runtime left the ordinary app registering no background tasks at all.
        if operation == .scheduledGuestTasks {
            return environment == .combinedGuestPrototype ? .unavailable(.notPartOfThisLayout) : .available
        }
        guard facts.runtimeLoaded, environment != .standalone else {
            // A combined build whose host answered but is missing an entry point is
            // not the same failure as an ordinary install with no host: telling
            // that user "the runtime is not loaded" sends them to reinstall the
            // app they already have.
            if environment != .standalone, !facts.missingHostSelectors.isEmpty {
                return .unavailable(.hostIncomplete)
            }
            return .unavailable(.runtimeNotLoaded)
        }

        switch operation {
        case .externalAppHandoff:
            return .unavailable(.unsupportedByDesign)
        case .embeddedContainerUI, .embeddedSideStoreSession, .guestImportStaging:
            return .available
        case .sessionSwitch:
            // Reachable, but it closes this process: the caller must ask first, which is why
            // the availability is paired with a reason in the UI rather than being a bare yes.
            return .available
        case .guestKeychainHooks:
            return environment == .combinedGuestPrototype
                ? .available
                : .unavailable(.notPartOfThisLayout)
        case .scheduledGuestTasks:
            return environment == .combinedGuestPrototype
                ? .unavailable(.notPartOfThisLayout)
                : .available
        }
    }

    // MARK: Diagnostics

    /// A redaction-safe description for the diagnostics export.
    ///
    /// Only the environment, the operation names and the reason codes: no paths, no bundle
    /// identifiers, no guest names. A support bundle should not carry a list of what the
    /// user runs.
    var jsonObject: [String: Any] {
        var operations: [String: Any] = [:]
        for operation in Operation.allCases {
            switch availability[operation] ?? .unavailable(.runtimeNotLoaded) {
            case .available:
                operations[operation.rawValue] = "available"
            case let .unavailable(reason):
                operations[operation.rawValue] = "unavailable:\(reason.rawValue)"
            }
        }
        return [
            "environment": environment.rawValue,
            "operations": operations
        ]
    }
}

// MARK: - Explaining a missing capability

extension RuntimeCapabilityReport.Reason {
    /// The sentence a screen shows when a control is unavailable, or `nil` when the reason is
    /// already carried by that control's own copy.
    ///
    /// The reason codes were only ever exported to diagnostics: a standalone build simply
    /// omitted the "Built-in apps" section and left the user to conclude the feature was broken
    /// or their device was at fault. Nothing was missing from the device — the embedded runtime
    /// is a different build — and that is worth saying where the user looks for the feature.
    var explanation: String? {
        switch self {
        case .runtimeNotLoaded:
            return .localized("LiveContainer and SideStore ship in the combined build, not in an ordinary install. This copy signs and installs apps; it cannot host them, and nothing is missing from your device.")
        case .hostIncomplete:
            return .localized("This is a combined build, and its host is an older or different version than this app expects. One of the two needs updating; reinstalling this app alone will not change it.")
        case .notPartOfThisLayout:
            return .localized("This layout of the combined app deliberately does not install that hook, so the operation restarts nothing and leaves no state behind.")
        case .restartsHost:
            return nil
        case .unsupportedByDesign:
            return .localized("VexSign never hands an import to a separately installed container: a detected URL handler does not prove that container would accept the file.")
        }
    }
}

extension RuntimeCapabilityReport {
    /// The explanation for the runtime operations this build cannot reach, in operation order.
    var unavailableExplanations: [(operation: Operation, explanation: String)] {
        Operation.allCases.compactMap { operation in
            guard let reason = reason(for: operation), let explanation = reason.explanation else { return nil }
            return (operation, explanation)
        }
    }
}

// MARK: - Session switch

extension RuntimeCapabilityReport {
    /// The confirmation text for a session switch, or nil when the operation is unavailable.
    ///
    /// Localized text lives here rather than in the report so the report stays a value that
    /// can be compared and exported without a translation catalogue.
    var sessionSwitchWarning: String? {
        guard isAvailable(.sessionSwitch) else { return nil }
        return .localized("Switching session restarts the host process. Save your work first; this does not confirm account login, signing or renewal.")
    }
}
