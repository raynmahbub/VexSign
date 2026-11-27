// MARK: - Dependency and conflict resolution for tweak packages
//
// Pure analysis over inspected package metadata. It never downloads or executes
// a dependency. A missing dependency stays a blocking finding until the user
// explicitly imports another package and includes it in the same plan.

import Foundation
import NimbleExtensions

struct InjectionDependencyResolution: Sendable {
    let outcome: InjectionOutcome
    let orderedPackageIDs: [String]
    let findings: [InjectionFinding]
    let requiredRuntimeLibraries: [String]
    let unmet: [String]
    let cycles: [[String]]
    let conflicts: [(first: String, second: String, reason: String)]
}

enum InjectionDependencyResolver {
    private static let runtimeNames: Set<String> = [
        "cydiasubstrate", "libsubstrate", "ellekit", "libellekit", "substitute", "libhooker"
    ]

    static func resolve(
        selected: [TweakPackageInspection],
        available: [TweakPackageInspection] = []
    ) -> InjectionDependencyResolution {
        let selectedIDs = Set(selected.map { $0.packageID?.lowercased() }.compactMap { $0 })
        let availableByID = Dictionary(
            (selected + available).compactMap { package -> (String, TweakPackageInspection)? in
                guard let id = package.packageID?.lowercased() else { return nil }
                return (id, package)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let provides = Set((selected + available).flatMap { package in
            package.provides.map(\.normalizedName)
        })

        var findings: [InjectionFinding] = []
        var unmet: [String] = []
        for package in selected {
            let requirements = package.preDepends + package.depends
            for requirement in requirements where !_isSystemRequirement(requirement.normalizedName) {
                let name = requirement.normalizedName
                guard !selectedIDs.contains(name), !provides.contains(name) else {
                    // A version constraint cannot be proven from a bare control
                    // string without a Debian version comparator; surface it.
                    if requirement.versionConstraint != nil,
                       let provider = availableByID[name],
                       provider.version != nil {
                        findings.append(InjectionFinding(
                            code: "versionConstraintUnverified",
                            severity: .advisory,
                            detail: String.localized(
                                "%@ requires %1$@ %2$@. VexSign cannot prove the installed version satisfies that constraint; verify it before applying.",
                                arguments: package.label, name, requirement.versionConstraint ?? ""
                            )
                        ))
                    }
                    continue
                }
                guard availableByID[name] != nil else {
                    unmet.append(name)
                    findings.append(InjectionFinding(
                        code: "missingDependency",
                        severity: .blocking,
                        detail: String.localized(
                            "%@ requires %@, which is not an imported package. Import it explicitly before applying this plan.",
                            arguments: package.label, name
                        )
                    ))
                    continue
                }
                findings.append(InjectionFinding(
                    code: "dependencyNotSelected",
                    severity: .blocking,
                    detail: String.localized(
                        "%@ requires %@. It is available in the library but is not selected for this application.",
                        arguments: package.label, name
                    )
                ))
            }
        }

        var conflicts: [(first: String, second: String, reason: String)] = []
        for (index, first) in selected.enumerated() {
            for second in selected.dropFirst(index + 1) {
                for relation in first.conflicts + first.breaks where relation.normalizedName == second.packageID?.lowercased() {
                    let reason = "\(first.label) declares a conflict with \(second.label)."
                    conflicts.append((first.label, second.label, reason))
                    findings.append(InjectionFinding(code: "packageConflict", severity: .blocking, detail: reason))
                }
                let sharedFiles = Set(first.installPaths).intersection(second.installPaths)
                if !sharedFiles.isEmpty {
                    let detail = String.localized(
                        "%1$@ and %2$@ both install %3$@. VexSign will not silently overwrite one with the other.",
                        arguments: first.label, second.label, sharedFiles.sorted().first ?? ""
                    )
                    conflicts.append((first.label, second.label, detail))
                    findings.append(InjectionFinding(code: "fileConflict", severity: .blocking, detail: detail))
                }
            }
        }

        let cycles = _cycles(in: selected)
        for cycle in cycles {
            findings.append(InjectionFinding(
                code: "dependencyCycle",
                severity: .blocking,
                detail: String.localized("A dependency cycle was found: %@", arguments: cycle.joined(separator: " → "))
            ))
        }

        let runtimes = Array(Set(selected.flatMap { package in
            package.depends.filter { runtimeNames.contains($0.normalizedName) }.map(\.normalizedName)
        })).sorted()

        let outcome: InjectionOutcome
        if !unmet.isEmpty { outcome = .missingDependency }
        else if !conflicts.isEmpty { outcome = .conflictingModification }
        else if !cycles.isEmpty { outcome = .incompatible }
        else if findings.contains(where: { $0.severity == .blocking }) { outcome = .incompatible }
        else if !findings.isEmpty { outcome = .requiresAdditionalValidation }
        else { outcome = .compatible }

        return InjectionDependencyResolution(
            outcome: outcome,
            orderedPackageIDs: selected.compactMap(\.packageID).map { $0.lowercased() },
            findings: findings,
            requiredRuntimeLibraries: runtimes,
            unmet: unmet.sorted(),
            cycles: cycles,
            conflicts: conflicts
        )
    }

    private static func _isSystemRequirement(_ name: String) -> Bool {
        name.hasPrefix("firmware") || name.hasPrefix("com.apple")
            || ["essential", "base-files", "dpkg", "libc6"].contains(name)
    }

    private static func _cycles(in packages: [TweakPackageInspection]) -> [[String]] {
        let ids = Set(packages.compactMap { $0.packageID?.lowercased() })
        var graph: [String: [String]] = [:]
        for package in packages {
            guard let id = package.packageID?.lowercased() else { continue }
            graph[id] = (package.depends + package.preDepends).map(\.normalizedName)
                .filter { ids.contains($0) }
        }
        var stacks: [[String]] = []
        var visited = Set<String>()
        var active = Set<String>()

        func visit(_ node: String, path: [String]) {
            guard !active.contains(node) else {
                if let start = path.firstIndex(of: node) {
                    stacks.append(Array(path[start...]) + [node])
                }
                return
            }
            guard !visited.contains(node) else { return }
            visited.insert(node)
            active.insert(node)
            for next in graph[node] ?? [] where graph.keys.contains(next) {
                visit(next, path: path + [node])
            }
            active.remove(node)
        }
        for node in graph.keys.sorted() { visit(node, path: []) }
        return stacks
    }
}
