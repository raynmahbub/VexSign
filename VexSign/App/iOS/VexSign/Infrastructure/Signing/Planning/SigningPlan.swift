import Foundation
import NimbleExtensions

/// One bounded manifest shared by review, admission and verification. The native
/// engine recursively discovers bundles, so discovery here must not silently
/// omit a deeper/unusual location or confuse a malformed framework with resources.
struct SigningPlan: Equatable {
    enum Kind: String, CaseIterable {
        case appExtension, watchApp, watchExtension, framework, dylib, plugin, embeddedApp, appClip, loadableBundle
        var requiresProfile: Bool {
            switch self {
            case .appExtension, .watchApp, .watchExtension, .plugin, .embeddedApp, .appClip: return true
            case .framework, .dylib, .loadableBundle: return false
            }
        }
    }

    struct Component: Equatable, Identifiable {
        let path: String
        let kind: Kind
        let identifier: String?
        let hasExecutable: Bool
        var isResourceOnly: Bool = false
        var id: String { path }
        var depth: Int { path.split(separator: "/").count }
        var displayName: String { (path as NSString).lastPathComponent }
        var isStructurallyComplete: Bool { hasExecutable && (kind == .dylib || identifier?.isEmpty == false) }
    }

    struct DiscoveryIssue: Equatable {
        let path: String
        let detail: String
    }
    let components: [Component]
    var discoveryIssues: [DiscoveryIssue] = []
    var isEmpty: Bool { components.isEmpty }
    var profileBoundComponents: [Component] { components.filter { $0.kind.requiresProfile } }

    static func make(appBundle: URL, maximumEntries: Int = 50_000, maximumDepth: Int = 32) -> SigningPlan {
        let manager = FileManager.default
        let root = appBundle.standardizedFileURL
        var found: [Component] = []
        var issues: [DiscoveryIssue] = []
        var entries = 0
        var seen = Set<String>()
        var executables = Set<URL>()
        var looseMachOs: [URL] = []
        if let executable = SigningInputValidation.executable(in: root) { executables.insert(executable.standardizedFileURL) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        func fail(_ path: String, _ detail: String) { issues.append(.init(path: path, detail: detail)) }
        func walk(_ directory: URL, depth: Int) {
            guard !Task.isCancelled else { fail(".", "Inspection was cancelled."); return }
            guard depth < maximumDepth else { fail(relative(directory), "The nested-code depth limit was reached; discovery is incomplete."); return }
            do {
                let contents = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
                for file in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    entries += 1
                    guard entries <= maximumEntries else { fail(".", "The bounded discovery limit was reached; no partial manifest is accepted."); return }
                    let path = relative(file)
                    let values = try file.resourceValues(forKeys: keys)
                    guard values.isSymbolicLink != true else {
                        // Even a directory without a bundle suffix can hide code
                        // behind a link. Never allow the engine to follow it.
                        fail(path, "Symbolic links in a signing tree are unsupported; import a complete device IPA with contained regular files.")
                        continue
                    }
                    guard seen.insert(path.lowercased()).inserted else { fail(path, "Case-colliding component paths are ambiguous."); continue }
                    if values.isDirectory == true {
                        let ext = file.pathExtension.lowercased()
                        let kind: Kind?
                        switch ext {
                        case "appex":
                            kind = path.split(separator: "/").contains("Watch") ? .watchExtension : (depth <= 1 ? .appExtension : .plugin)
                        case "app":
                            kind = path.split(separator: "/").contains("Watch") ? .watchApp
                                : (path.split(separator: "/").contains("AppClips") ? .appClip : .embeddedApp)
                        case "framework": kind = .framework
                        case "bundle": kind = .loadableBundle
                        case "xpc", "xctest":
                            fail(path, "This executable bundle type is not supported for device signing.")
                            kind = nil
                        default: kind = nil
                        }
                        if let kind {
                            if let executable = SigningInputValidation.executable(in: file) { executables.insert(executable.standardizedFileURL) }
                            let info = try? info(at: file) // try? ok: missing/malformed metadata is blocking below, never resource-only evidence.
                            let resourceOnly = [Kind.framework, .loadableBundle].contains(kind) && isResourceOnlyBundle(file)
                            // Ordinary .bundle resource packages are sealed by their parent.
                            if kind != .loadableBundle || !resourceOnly {
                                found.append(.init(path: path, kind: kind, identifier: info?["CFBundleIdentifier"] as? String,
                                    hasExecutable: SigningInputValidation.executable(in: file).map(isReadableMachO) ?? false,
                                    isResourceOnly: resourceOnly))
                            }
                        }
                        walk(file, depth: depth + 1)
                    } else if values.isRegularFile == true {
                        if file.pathExtension.lowercased() == "dylib" {
                            found.append(.init(path: path, kind: .dylib, identifier: nil, hasExecutable: isReadableMachO(file)))
                        } else if try hasMachOMagic(file) { looseMachOs.append(file.standardizedFileURL) }
                    } else { fail(path, "Non-regular files in a signing tree are unsupported.") }
                }
            } catch { fail(relative(directory), "This directory could not be completely inspected.") }
        }
        func relative(_ url: URL) -> String {
            guard url.path.hasPrefix(root.path + "/") else { return "." }
            return String(url.path.dropFirst(root.path.count + 1))
        }
        do {
            let values = try root.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                return .init(components: [], discoveryIssues: [.init(path: ".", detail: "The application directory is missing or is a symbolic link.")])
            }
            walk(root, depth: 0)
        } catch { fail(".", "The application directory could not be inspected.") }
        for file in looseMachOs where !executables.contains(file) {
            fail(relative(file), "A loose Mach-O file has no supported signing role. Move it into its declared executable bundle or import a complete IPA; it will not be left unsigned as a resource.")
        }
        return SigningPlan(components: found.sorted {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            return $0.path < $1.path
        }, discoveryIssues: issues)
    }

    func validationIssues() -> [SigningCapability.Issue] {
        var issues = discoveryIssues.map { problem in
            SigningCapability.Issue(code: .nestedComponentInvalid, severity: .blocking, status: .unsupported,
                title: "Incomplete signing manifest", detail: problem.path + ": " + problem.detail)
        }
        for component in components {
            if component.isResourceOnly {
                issues.append(.init(code: .nestedComponentInvalid, severity: .advisory, status: .supported,
                    title: "Resource-only bundle", detail: component.path + " has positive resource-only evidence. Its resources are sealed by the containing app."))
                continue
            }
            if component.kind != .dylib && component.identifier?.isEmpty != false {
                issues.append(.init(code: .bundleIdentifierMissing, severity: .blocking, status: .invalid,
                    title: "Component has no identifier", detail: component.path + " has no usable CFBundleIdentifier.",
                    remediation: "Import a complete device build of this application."))
            }
            if !component.hasExecutable {
                issues.append(.init(code: .executableUnavailable, severity: .blocking, status: .invalid,
                    title: "Component executable unavailable", detail: component.path + " has no readable, contained Mach-O executable. A missing framework binary is not resource-only evidence.",
                    remediation: "Replace the malformed component or import a complete IPA."))
            }
        }
        return issues
    }

    /// Explicit BNDL metadata, no declared or basename executable, and no hidden
    /// Mach-O/symlink/unreadable descendant. Absence of CFBundleExecutable alone
    /// never turns a FMWK into a resource-only package.
    static func isResourceOnlyBundle(_ url: URL) -> Bool {
        guard let metadata = try? info(at: url), metadata["CFBundlePackageType"] as? String == "BNDL", // try? ok: unreadable metadata means no positive resource-only evidence.
              metadata["CFBundleExecutable"] == nil,
              !FileManager.default.fileExists(atPath: url.appendingPathComponent(url.deletingPathExtension().lastPathComponent).path) else { return false }
        var failed = false
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, _ in failed = true; return false }) else { return false }
        var count = 0
        do {
            for case let file as URL in walker {
                count += 1
                guard count <= 50_000, !Task.isCancelled else { return false }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { return false }
                if values.isRegularFile == true {
                    if try hasMachOMagic(file) { return false }
                }
            }
        } catch { return false }
        return !failed
    }

    private static func hasMachOMagic(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() } // try? ok: only closes the bounded read; read errors propagate.
        let bytes = try handle.read(upToCount: 4) ?? Data()
        guard let magic = MachOReader.u32(bytes, at: 0, bigEndian: false) else { return false }
        return [UInt32(0xfeedface), 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xbebafeca, 0xbfbafeca, 0xcafebabe, 0xcafebabf].contains(magic)
    }

    private static func info(at bundle: URL) throws -> [String: Any] {
        let bytes = try CertificateInputReader.read(bundle.appendingPathComponent("Info.plist"))
        guard let dictionary = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        return dictionary
    }

    private static func isReadableMachO(_ file: URL) -> Bool {
        do { return ExecutablePreflight.inspectSlices(try Data(contentsOf: file, options: .mappedIfSafe)) != nil }
        catch { return false }
    }
}
