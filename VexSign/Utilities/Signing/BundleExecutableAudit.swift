import Foundation
import NimbleExtensions

/// Shared UI/worker evidence. Reads declared bundle executables and dylibs, not arbitrary resources.
/// Device-minimum comparisons belong to UI review; signing can also prepare companion-device apps.
enum BundleExecutableAudit {
    enum Problem: String { case unreadable, malformed, encrypted, unsupportedDeviceBinary, unknownPlatform }
    struct Finding: Identifiable, Equatable {
        let path: String
        let problem: Problem
        var id: String { path + ":" + problem.rawValue }
        var isBlocking: Bool { problem != .unknownPlatform }
        var detail: String {
            switch problem {
            case .unreadable: return .localized("The declared executable could not be read safely: %@", arguments: path)
            case .malformed: return .localized("Mach-O slice bounds or load commands are invalid or unsupported: %@", arguments: path)
            case .encrypted: return .localized("An executable slice declares encryption. Re-signing does not decrypt it: %@", arguments: path)
            case .unsupportedDeviceBinary: return .localized("An iOS bundle has no arm64 iOS-device executable slice: %@", arguments: path)
            case .unknownPlatform: return .localized("The executable platform could not be established: %@", arguments: path)
            }
        }
    }
    struct Report {
        let inspected: Int
        let findings: [Finding]
        var blocking: [Finding] { findings.filter(\.isBlocking) }
    }

    static func inspect(_ bundle: URL, maximumEntries: Int = 50000, excludingBundlePaths: Set<String> = []) throws -> Report {
        let manager = FileManager.default
        let root = bundle.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var findings: [Finding] = []
        var inspected = Set<URL>()
        var walkError: Error?

        func inspectExecutable(_ executable: URL?, label: String, needsIOSDevice: Bool) throws {
            try Task.checkCancellation()
            guard let executable else { findings.append(.init(path: label, problem: .unreadable)); return }
            let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/"),
                  try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                findings.append(.init(path: label, problem: .unreadable)); return
            }
            guard inspected.insert(resolved).inserted else { return }
            let slices: [ExecutablePreflight.Evidence]
            do {
                let data = try Data(contentsOf: resolved, options: .mappedIfSafe)
                guard let result = ExecutablePreflight.inspectSlices(data) else {
                    findings.append(.init(path: label, problem: .malformed)); return
                }
                slices = result
            } catch {
                findings.append(.init(path: label, problem: .unreadable)); return
            }
            if slices.contains(where: { $0.encrypted }) { findings.append(.init(path: label, problem: .encrypted)) }
            if needsIOSDevice {
                let device = slices.filter { $0.isArm64 }
                if device.isEmpty || device.allSatisfy({ $0.platform != nil && $0.platform != 2 }) {
                    findings.append(.init(path: label, problem: .unsupportedDeviceBinary))
                } else if device.allSatisfy({ $0.platform == nil }) {
                    findings.append(.init(path: label, problem: .unknownPlatform))
                }
            }
        }

        try inspectExecutable(SigningInputValidation.executable(in: root), label: root.lastPathComponent, needsIOSDevice: true)
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, error in
            walkError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        var entries = 0
        for case let file as URL in walker {
            try Task.checkCancellation()
            entries += 1
            guard entries <= maximumEntries else { throw CocoaError(.fileReadTooLarge) }
            let values = try file.resourceValues(forKeys: Set(keys))
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let ext = file.pathExtension.lowercased()
            if excludingBundlePaths.contains(relative) {
                walker.skipDescendants()
                continue
            }
            if values.isSymbolicLink == true {
                walker.skipDescendants()
                if ["app", "appex", "framework", "xpc", "dylib"].contains(ext) {
                    findings.append(.init(path: relative, problem: .unreadable))
                }
                continue
            }
            if values.isDirectory == true && ["app", "appex", "framework", "xpc"].contains(ext) {
                // Watch apps/frameworks have other CPU/platform requirements, not host-iOS requirements.
                let isWatch = relative.split(separator: "/").contains("Watch")
                try inspectExecutable(SigningInputValidation.executable(in: file), label: relative, needsIOSDevice: !isWatch)
            } else if values.isRegularFile == true && ext == "dylib" {
                try inspectExecutable(file, label: relative, needsIOSDevice: false)
            }
        }
        if let walkError { throw walkError }
        return Report(inspected: inspected.count, findings: findings)
    }

    static func requireSignable(_ bundle: URL) throws {
        let report = try inspect(bundle)
        if let failure = report.blocking.first {
            throw SigningFileHandlerError.identityRejected(failure.detail)
        }
    }
}
