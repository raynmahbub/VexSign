// MARK: - Authorized target gate
//
// A structured modification plan carries explicit include/exclude rules. When
// those rules are present, the signing engine asks this gate before it places
// or injects anything. Absent or malformed rules select nothing: there is no
// implicit "inject into every app" fallback.

import Foundation

enum InjectionTargetAuthorization {
    static func targets(in app: URL, bundleIdentifier: String?) -> [InjectionTarget] {
        let infoURL = app.appendingPathComponent("Info.plist")
        let plistObject = try? PropertyListSerialization.propertyList( // try? ok: a malformed Info.plist leaves the target unidentified and refuses injection
            from: Data(contentsOf: infoURL), options: [], format: nil
        )
        let plist = plistObject as? [String: Any]
        let executableName: String? = {
            guard let plist else { return nil }
            return plist["CFBundleExecutable"] as? String
        }()
        let bundleFromPlist: String? = {
            guard let plist else { return nil }
            return plist["CFBundleIdentifier"] as? String
        }()
        let resolvedID = bundleIdentifier ?? bundleFromPlist
        let displayName = executableName ?? app.deletingPathExtension().lastPathComponent

        var result: [InjectionTarget] = []
        if let resolvedID, !resolvedID.isEmpty {
            result.append(InjectionTarget(
                id: "main", displayName: displayName, bundleIdentifier: resolvedID,
                executableName: executableName, isMain: true
            ))
        }
        let plugins = app.appendingPathComponent("PlugIns")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: plugins.path)) ?? [] // try? ok: no PlugIns directory means no extensions to consider
        for name in names where name.hasSuffix(".appex") {
            let suffix = (name as NSString).deletingPathExtension
            result.append(InjectionTarget(
                id: "extension-\(suffix)", displayName: suffix,
                bundleIdentifier: resolvedID.map { "\($0).\(suffix)" },
                executableName: suffix, isMain: false
            ))
        }
        return result
    }

    /// Returns the evaluation and whether injection may proceed. An empty rule
    /// set is allowed only for the legacy explicit-file flow, which the caller
    /// handles separately; here an empty set never authorizes a target.
    static func evaluate(
        configurations: [InjectionConfiguration],
        in app: URL,
        bundleIdentifier: String?
    ) -> InjectionConfigurationResult {
        guard !configurations.isEmpty else {
            return InjectionConfigurationResult(
                outcome: .requiresAdditionalValidation,
                selections: [],
                explanations: ["No structured injection rules were supplied for this signing run."],
                conflictingRuleIDs: []
            )
        }
        return InjectionConfigurationEngine.evaluate(
            configurations: configurations,
            targets: targets(in: app, bundleIdentifier: bundleIdentifier)
        )
    }
}
