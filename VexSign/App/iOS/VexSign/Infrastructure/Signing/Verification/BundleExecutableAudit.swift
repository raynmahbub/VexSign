import Foundation
import NimbleExtensions

/// Review and the final worker inspect the same recursive signing manifest.
/// All retained slices are bounded, unencrypted, correctly typed device code.
extension BundleExecutableAudit {
    static func inspect(_ bundle: URL, maximumEntries: Int = 50_000, excludingBundlePaths: Set<String> = []) throws -> Report {
        let plan = SigningPlan.make(appBundle: bundle, maximumEntries: maximumEntries)
        let root = bundle.standardizedFileURL
        var findings: [Finding] = []
        var inspected = Set<URL>()
        func excluded(_ path: String) -> Bool {
            excludingBundlePaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        for problem in plan.discoveryIssues where !excluded(problem.path) {
            findings.append(.init(path: problem.path, problem: .discoveryIncomplete))
        }
        func inspectExecutable(_ executable: URL?, label: String, watch: Bool, types: Set<UInt32>) throws {
            try Task.checkCancellation()
            guard let executable else { findings.append(.init(path: label, problem: .unreadable)); return }
            let properties = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard executable.standardizedFileURL.path.hasPrefix(root.path + "/"),
                  properties.isRegularFile == true, properties.isSymbolicLink != true else {
                findings.append(.init(path: label, problem: .unreadable)); return
            }
            guard inspected.insert(executable.standardizedFileURL).inserted else { return }
            let slices: [ExecutablePreflight.Evidence]
            do {
                let data = try Data(contentsOf: executable, options: .mappedIfSafe)
                guard let values = ExecutablePreflight.inspectSlices(data) else { findings.append(.init(path: label, problem: .malformed)); return }
                slices = values
            } catch { findings.append(.init(path: label, problem: .unreadable)); return }
            if slices.contains(where: { $0.encrypted }) { findings.append(.init(path: label, problem: .encrypted)) }
            if slices.contains(where: { !types.contains($0.fileType) }) { findings.append(.init(path: label, problem: .unexpectedFileType)) }
            if slices.contains(where: { $0.platform == nil }) { findings.append(.init(path: label, problem: .unknownPlatform)) }
            if watch {
                if !slices.contains(where: { [UInt32(12), 0x0100000c, 0x0200000c].contains($0.cpuType) && $0.platform == 4 })
                    || slices.contains(where: { ![UInt32(12), 0x0100000c, 0x0200000c].contains($0.cpuType) || ($0.platform != nil && $0.platform != 4) }) {
                    findings.append(.init(path: label, problem: .unsupportedCompanionBinary))
                }
            } else if !slices.contains(where: { $0.isArm64 && $0.platform == 2 })
                || slices.contains(where: { ![UInt32(12), 0x0100000c].contains($0.cpuType) || ($0.platform != nil && $0.platform != 2) }) {
                findings.append(.init(path: label, problem: .unsupportedDeviceBinary))
            }
        }
        try inspectExecutable(SigningInputValidation.executable(in: root), label: root.lastPathComponent, watch: false, types: [2])
        for component in plan.components where !excluded(component.path) && !component.isResourceOnly {
            let url = root.appendingPathComponent(component.path)
            let executable = component.kind == .dylib ? url : SigningInputValidation.executable(in: url)
            let types: Set<UInt32> = component.kind.requiresProfile ? [2] : (component.kind == .loadableBundle ? [8] : [6])
            try inspectExecutable(executable, label: component.path,
                watch: component.path.split(separator: "/").contains("Watch"), types: types)
        }
        return Report(inspected: inspected.count, findings: findings)
    }

    static func requireSignable(_ bundle: URL) throws {
        let report = try inspect(bundle)
        if let failure = report.blocking.first { throw SigningFileHandlerError.identityRejected(failure.detail) }
    }
}
