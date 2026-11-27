// MARK: - Injection filter evaluation
//
// Pure, deterministic decisions: which tweaks apply to which executable of an
// application, and why. Malformed or absent filters never widen the target set.

import Foundation
import NimbleExtensions

struct InjectionSelection: Codable, Equatable, Sendable, Identifiable {
    let configurationID: String
    let targetID: String
    let reasons: [String]
    var id: String { configurationID + "|" + targetID }
}

struct InjectionConfigurationResult: Codable, Equatable, Sendable {
    let outcome: InjectionOutcome
    let selections: [InjectionSelection]
    let explanations: [String]
    let conflictingRuleIDs: [String]
}

enum InjectionConfigurationEngine {
    static func evaluate(
        configurations: [InjectionConfiguration],
        targets: [InjectionTarget],
        executableInstallNames: [String: String] = [:]
    ) -> InjectionConfigurationResult {
        var explanations: [String] = []
        var selections: [InjectionSelection] = []
        var conflicting: [String] = []
        var hasInvalidRule = false

        for configuration in configurations {
            guard configuration.enabled else {
                explanations.append(String.localized("%@ is disabled; it was not considered for any target.", arguments: configuration.packageID))
                continue
            }
            guard !configuration.declaresNoTargets else {
                explanations.append(String.localized(
                    "%@ declares no bundle or executable filter, so it was not applied to any target.",
                    arguments: configuration.packageID
                ))
                continue
            }
            let invalid = (configuration.bundleRules + configuration.executableRules).filter {
                InjectionFilterRule.validate(pattern: $0.pattern) != nil
            }
            if !invalid.isEmpty {
                hasInvalidRule = true
                explanations.append(String.localized(
                    "%@ has an invalid injection filter and was refused for every target.",
                    arguments: configuration.packageID
                ))
                continue
            }

            let selfExcluded = configuration.excludedBundleIDs.filter { excluded in
                configuration.bundleRules.contains { $0.kind == .bundle && $0.matches(excluded) }
            }
            if !selfExcluded.isEmpty {
                conflicting.append(configuration.packageID)
                explanations.append(String.localized(
                    "%@ both selects and excludes %@. The rule is contradictory; nothing was injected into that target.",
                    arguments: configuration.packageID, selfExcluded.joined(separator: ", ")
                ))
            }

            for target in targets {
                var reasons: [String] = []
                let bundleID = target.bundleIdentifier ?? ""
                let executableName = target.executableName ?? ""
                let installName = executableInstallNames[target.id] ?? ""

                if configuration.excludedBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                    explanations.append(String.localized(
                        "%@ is excluded from %@ by the configuration.", arguments: configuration.packageID, bundleID
                    ))
                    continue
                }

                let bundleMatches = configuration.bundleRules.filter { $0.kind == .bundle && $0.matches(bundleID) }
                let executableMatches = configuration.executableRules.filter {
                    $0.kind == .executable && ($0.matches(executableName) || (!installName.isEmpty && $0.matches(installName)))
                }
                guard !bundleMatches.isEmpty || !executableMatches.isEmpty else {
                    explanations.append(String.localized(
                        "%@ does not match %@ and was not injected there.", arguments: configuration.packageID, bundleID
                    ))
                    continue
                }
                reasons.append(contentsOf: bundleMatches.map { "Bundle filter \($0.pattern) matched \(bundleID)." })
                reasons.append(contentsOf: executableMatches.map { "Executable filter \($0.pattern) matched \(executableName)." })
                if target.isMain {
                    reasons.append("This is the main application executable.")
                } else {
                    reasons.append("This is a nested executable; its own architecture and signature will be checked before injection.")
                }
                selections.append(InjectionSelection(
                    configurationID: configuration.packageID,
                    targetID: target.id,
                    reasons: reasons
                ))
            }
        }

        // Two active configurations that select the same target with rules that
        // deny each other's bundle are ambiguous. Do not pick a winner silently.
        for selection in selections {
            guard let target = targets.first(where: { $0.id == selection.targetID }),
                  let bundleID = target.bundleIdentifier else { continue }
            let matching = configurations.filter { config in
                config.enabled && config.excludedBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
            }
            let selectedIDs = Set(selections.filter { $0.targetID == target.id }.map(\.configurationID))
            for config in matching where selectedIDs.contains(config.packageID) {
                conflicting.append(config.packageID)
                explanations.append(String.localized(
                    "%@ both selects and excludes %@. The rule is contradictory; nothing was injected into that target.",
                    arguments: config.packageID, bundleID
                ))
            }
        }
        conflicting = Array(Set(conflicting)).sorted()

        let outcome: InjectionOutcome
        if hasInvalidRule { outcome = .invalidPackage }
        else if !conflicting.isEmpty { outcome = .conflictingModification }
        else if selections.isEmpty { outcome = .requiresAdditionalValidation }
        else { outcome = .compatible }

        return InjectionConfigurationResult(
            outcome: outcome,
            selections: conflicting.isEmpty ? selections : [],
            explanations: explanations,
            conflictingRuleIDs: conflicting
        )
    }
}
