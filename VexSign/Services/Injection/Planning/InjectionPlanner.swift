// MARK: - Modification plan assembly
//
// Combines package inspection, dependency analysis, filter decisions and Mach-O
// validation into one auditable plan. It never mutates a bundle. The plan is
// what the preview screen shows and what the signing step is required to obey.

import Foundation
import NimbleExtensions

struct InjectionPlanningInput: Sendable {
    let appIdentifier: String?
    let targets: [InjectionTarget]
    let inspections: [TweakPackageInspection]
    let configurations: [InjectionConfiguration]
    let binaryFindings: [InjectionFinding]
    let hookRuntimeAvailable: Bool

    init(
        appIdentifier: String?,
        targets: [InjectionTarget],
        inspections: [TweakPackageInspection],
        configurations: [InjectionConfiguration],
        binaryFindings: [InjectionFinding] = [],
        hookRuntimeAvailable: Bool = true
    ) {
        self.appIdentifier = appIdentifier
        self.targets = targets
        self.inspections = inspections
        self.configurations = configurations
        self.binaryFindings = binaryFindings
        self.hookRuntimeAvailable = hookRuntimeAvailable
    }
}

enum InjectionPlanner {
    static func makePlan(
        id: String = UUID().uuidString,
        input: InjectionPlanningInput
    ) -> InjectionPlan {
        let configurationResult = InjectionConfigurationEngine.evaluate(
            configurations: input.configurations,
            targets: input.targets
        )
        let dependencyResult = InjectionDependencyResolver.resolve(selected: input.inspections)
        var findings = configurationResult.explanations.map {
            InjectionFinding(code: "filterDecision", severity: .informational, detail: $0)
        }
        findings += input.configurations.flatMap(\.bundleRules).compactMap { rule in
            InjectionFilterRule.validate(pattern: rule.pattern).map {
                InjectionFinding(code: "invalidFilter", severity: .blocking, detail: "\($0.description): \(rule.pattern)")
            }
        }
        findings += dependencyResult.findings
        findings += input.binaryFindings

        let selectedIDs = Set(configurationResult.selections.map(\.configurationID))
        var excludedIDs = Set(input.inspections.compactMap(\.packageID)).subtracting(selectedIDs)

        if !input.hookRuntimeAvailable, dependencyResult.requiredRuntimeLibraries.isEmpty {
            findings.append(InjectionFinding(
                code: "hookRuntimeUnavailable", severity: .blocking,
                detail: .localized("This tweak needs a hooking runtime, but no bundled runtime is available. Nothing was planned.")
            ))
        }

        // A selected package whose binary is not importable must not produce steps.
        let importableIDs = Set(input.inspections.filter { $0.outcome.permitsInjection }.compactMap(\.packageID))
        for id in selectedIDs where !importableIDs.contains(id) {
            findings.append(InjectionFinding(
                code: "packageNotImportable", severity: .blocking,
                detail: String.localized("The selected package %@ failed inspection and was excluded.", arguments: id)
            ))
        }
        excludedIDs.formUnion(selectedIDs.subtracting(importableIDs))

        let outcome: InjectionOutcome = {
            if findings.contains(where: { $0.severity == .blocking }) { return .incompatible }
            switch configurationResult.outcome {
            case .invalidPackage: return .invalidPackage
            case .conflictingModification: return .conflictingModification
            case .missingDependency: return .missingDependency
            case .requiresAdditionalValidation where configurationResult.selections.isEmpty:
                return .requiresAdditionalValidation
            default: break
            }
            switch dependencyResult.outcome {
            case .invalidPackage, .incompatible, .missingDependency, .conflictingModification,
                 .requiresAdditionalValidation: return dependencyResult.outcome
            default: return .compatible
            }
        }()

        let selectedTargets = Set(configurationResult.selections.map(\.targetID))
        var steps: [InjectionStep] = []
        if outcome.permitsInjection {
            for inspection in input.inspections where importableIDs.contains(inspection.packageID ?? "") {
                steps.append(InjectionStep(
                    id: "place-\(inspection.packageID ?? inspection.fileName)",
                    kind: .placePayload,
                    summary: String.localized(
                        "Copy %1$@ payload (%2$@) into the app's Frameworks or PlugIns directory.",
                        arguments: inspection.label,
                        "\(inspection.dylibs.count + inspection.frameworks.count + inspection.bundles.count)"
                    ),
                    targetID: nil
                ))
            }
            for target in input.targets where selectedTargets.contains(target.id) {
                steps.append(InjectionStep(
                    id: "inject-\(target.id)",
                    kind: .addLoadCommand,
                    summary: String.localized("Add one LC_LOAD_DYLIB per selected tweak to %@.", arguments: target.displayName),
                    targetID: target.id
                ))
                if !target.isMain {
                    steps.append(InjectionStep(
                        id: "nested-\(target.id)",
                        kind: .reSignNestedCode,
                        summary: String.localized("Sign nested executable %@ before its enclosing application.", arguments: target.displayName),
                        targetID: target.id
                    ))
                }
            }
            steps.append(InjectionStep(
                id: "verify-final",
                kind: .verifySignature,
                summary: "Rebuild resource seals, verify every nested signature and inspect the final IPA.",
                targetID: nil
            ))
        }

        return InjectionPlan(
            id: id,
            appIdentifier: input.appIdentifier,
            targets: input.targets.filter { selectedTargets.contains($0.id) },
            steps: steps,
            selectedPackageIDs: selectedIDs.sorted(),
            excludedPackageIDs: excludedIDs.sorted(),
            findings: findings,
            outcome: outcome,
            requiresSignatureVerification: true
        )
    }
}
