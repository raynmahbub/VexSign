// MARK: - Debian tweak package inspection
//
// Reads the `ar` envelope, control metadata and data tree of a `.deb` without
// executing scripts or binaries. Every parsed value is bounded and every
// extracted path is checked before it reaches disk. The result is a report the
// UI can show and the planner can consume; it never mutates an application.

import Foundation
import NimbleExtensions

struct TweakPackageInspection: Codable, Equatable, Sendable {
    let fileName: String
    let packageID: String?
    let name: String?
    let version: String?
    let architecture: String?
    let maintainer: String?
    let description: String?
    let depends: [PackageRelation]
    let preDepends: [PackageRelation]
    let conflicts: [PackageRelation]
    let breaks: [PackageRelation]
    let provides: [PackageRelation]
    let ignoredScripts: [String]
    let installPaths: [String]
    let dylibs: [String]
    let frameworks: [String]
    let bundles: [String]
    let filters: [String: TweakFilterMetadata]
    let filterErrors: [String]
    let layout: TweakPackageLayout
    let findings: [InjectionFinding]
    let outcome: InjectionOutcome

    var label: String { name ?? packageID ?? fileName }
}

enum TweakPackageInspectorError: LocalizedError, Equatable {
    case unreadable
    case tooLarge
    case invalidEnvelope(String)
    case missingControl
    case missingData
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return .localized("The tweak package could not be read.")
        case .tooLarge: return .localized("The tweak package is too large to inspect safely.")
        case .invalidEnvelope(let detail):
            return String.localized("The Debian package envelope is invalid: %@", arguments: detail)
        case .missingControl: return .localized("The Debian package has no readable control metadata.")
        case .missingData: return .localized("The Debian package has no data archive.")
        case .extractionFailed(let detail):
            return String.localized("The tweak package could not be unpacked safely: %@", arguments: detail)
        }
    }
}

enum TweakPackageInspector {
    private static let maximumPackageBytes: Int64 = 128 * 1024 * 1024
    private static let maximumInstallPaths = 4_096

    /// Presentation may ask whether an artifact is still present without touching
    /// the file system itself.
    static func artifactExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Inspects one `.deb`. All extraction happens in a private temporary
    /// directory that is removed before this returns, on success or failure.
    static func inspect(
        fileAt url: URL,
        limits: StrictTarExtractor.Limits = .default,
        fileManager: FileManager = .default
    ) async throws -> TweakPackageInspection {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fileManager.attributesOfItem(atPath: url.path) }
        catch { throw TweakPackageInspectorError.unreadable }
        if let size = attributes[.size] as? NSNumber, size.int64Value > maximumPackageBytes {
            throw TweakPackageInspectorError.tooLarge
        }

        let work = fileManager.temporaryDirectory
            .appendingPathComponent("VexSignPackageInspection_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) } // try? ok: inspection results never depend on cleanup success

        do {
            // The ar envelope is read by AR's bounds-checked parser, not by the
            // ZIP extractor (which never accepts a .deb). StrictTarExtractor
            // independently checks every tar path before writing any member.
            let arEnvelope = try AR(with: url)
            let members = try await arEnvelope.extract()
            guard let debianVersion = members.first(where: { $0.name == "debian-binary" }) else {
                throw TweakPackageInspectorError.invalidEnvelope("debian-binary is missing")
            }
            let versionText = String(data: debianVersion.content, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard versionText == "2.0" || versionText == "1.0" else {
                throw TweakPackageInspectorError.invalidEnvelope("unsupported debian-binary version")
            }
            let controlNames = members.map(\.name).filter { $0 == "control.tar" || $0.hasPrefix("control.tar.") }
            guard controlNames.count == 1, let controlName = controlNames.first else {
                throw TweakPackageInspectorError.missingControl
            }
            let dataName = try DebianDataMember.select(from: members.map(\.name))
            guard let controlMember = members.first(where: { $0.name == controlName }),
                  let dataMember = members.first(where: { $0.name == dataName }) else {
                throw TweakPackageInspectorError.missingData
            }

            let controlRoot = try StrictTarExtractor.extract(
                memberData: controlMember.content,
                memberName: controlName,
                into: work.appendingPathComponent("control", isDirectory: true),
                limits: limits,
                fileManager: fileManager
            )
            let dataRoot = try StrictTarExtractor.extract(
                memberData: dataMember.content,
                memberName: dataName,
                into: work.appendingPathComponent("data", isDirectory: true),
                limits: limits,
                fileManager: fileManager
            )

            let controlURL = try _locateControlFile(in: controlRoot, fileManager: fileManager)
            let controlData = try Data(contentsOf: controlURL)
            guard let controlText = String(data: controlData, encoding: .utf8) else {
                throw TweakPackageInspectorError.missingControl
            }
            let fields = _parseControl(controlText)
            guard fields["package"]?.isEmpty == false, fields["version"]?.isEmpty == false else {
                throw TweakPackageInspectorError.missingControl
            }

            let entries = try _listFiles(in: dataRoot, fileManager: fileManager)
            guard entries.count <= maximumInstallPaths else { throw StrictTarExtractorError.tooManyEntries }
            let installPaths = entries.map { $0.path }
            let dylibs = installPaths.filter { $0.pathExtension.lowercased() == "dylib" }
            let frameworkExecutables = entries.filter { entry in
                guard entry.path.contains(".framework/") else { return false }
                let tail = String(entry.path.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
                return !tail.isEmpty && !tail.contains(".")
            }.map(\.path)
            let frameworks = Array(Set(frameworkExecutables.map { path in
                path.components(separatedBy: ".framework/").first.map { $0 + ".framework" } ?? path
            })).sorted()
            let bundles = installPaths.filter {
                $0.contains(".bundle/") || $0.pathExtension.lowercased() == "bundle"
            }

            let scripts = installPaths.filter { path in
                let name = (path as NSString).lastPathComponent.lowercased()
                return ["preinst", "postinst", "prerm", "postrm"].contains(name)
            }
            let (filters, filterErrors) = _readFilters(in: entries, binaryNames: dylibs + frameworkExecutables)

            let hasRoot = installPaths.contains { path in
                TweakPackageLayout.payloadDirectories.contains { payloadDirectory in
                    path.hasPrefix(payloadDirectory)
                }
            }
            let hasRootless = installPaths.contains { path in
                guard path.hasPrefix(TweakPackageLayout.rootlessPrefix) else { return false }
                let relative = String(path.dropFirst(TweakPackageLayout.rootlessPrefix.count))
                return TweakPackageLayout.payloadDirectories.contains { payloadDirectory in
                    relative.hasPrefix(payloadDirectory)
                }
            }
            let hasClassifiedPayload = hasRoot || hasRootless
            let declared = TweakPackageLayout(declaredArchitecture: fields["architecture"])
            let resolution = TweakCompatibility.resolveLayout(
                declaredArchitecture: fields["architecture"],
                hasRootPayload: hasRoot,
                hasRootlessPayload: hasRootless
            )

            var compatibilityFindings = resolution.findings
            if let declared, let observed = _observedLayout(hasRoot: hasRoot, hasRootless: hasRootless),
               declared != observed, declared != .unknown, observed != .unknown {
                compatibilityFindings.append(TweakCompatibility.Finding(
                    code: .layoutMismatch(declared: declared, observed: observed)
                ))
            }
            var findings = compatibilityFindings.map {
                InjectionFinding(
                    code: _code(of: $0),
                    severity: $0.isBlocking ? .blocking : .advisory,
                    detail: $0.message
                )
            }
            filterErrors.forEach {
                findings.append(InjectionFinding(code: "invalidFilter", severity: .blocking, detail: $0))
            }
            if !scripts.isEmpty {
                findings.append(InjectionFinding(
                    code: "scriptsIgnored", severity: .informational,
                    detail: .localized("Maintenance scripts in this package are read but never executed or installed.")
                ))
            }
            if !hasClassifiedPayload || dylibs.isEmpty && frameworks.isEmpty && bundles.isEmpty {
                findings.append(InjectionFinding(
                    code: "noInjectablePayload", severity: .blocking,
                    detail: .localized("This package contains no dylib, framework or resource bundle that VexSign can inject.")
                ))
            }

            let outcome: InjectionOutcome
            if resolution.isBlocked || !filterErrors.isEmpty || !hasClassifiedPayload
                || dylibs.isEmpty && frameworks.isEmpty && bundles.isEmpty {
                outcome = .invalidPackage
            } else if resolution.layout == .rootless || resolution.layout == .roothide || !scripts.isEmpty
                || !findings.contains(where: { $0.severity == .blocking }) && findings.count > 0 {
                outcome = .requiresAdditionalValidation
            } else {
                outcome = .compatible
            }

            return TweakPackageInspection(
                fileName: url.lastPathComponent,
                packageID: fields["package"],
                name: fields["name"],
                version: fields["version"],
                architecture: fields["architecture"],
                maintainer: fields["maintainer"],
                description: fields["description"],
                depends: PackageRelationParser.parse(fields["depends"]),
                preDepends: PackageRelationParser.parse(fields["pre-depends"]),
                conflicts: PackageRelationParser.parse(fields["conflicts"]),
                breaks: PackageRelationParser.parse(fields["breaks"]),
                provides: PackageRelationParser.parse(fields["provides"]),
                ignoredScripts: scripts.map { ($0 as NSString).lastPathComponent },
                installPaths: installPaths.sorted(),
                dylibs: dylibs.sorted(),
                frameworks: frameworks.sorted(),
                bundles: bundles.sorted(),
                filters: filters,
                filterErrors: filterErrors,
                layout: resolution.layout,
                findings: findings,
                outcome: outcome
            )
        } catch let error as StrictTarExtractorError {
            throw TweakPackageInspectorError.extractionFailed(error.localizedDescription)
        } catch let error as TweakPackageInspectorError {
            throw error
        } catch {
            throw TweakPackageInspectorError.extractionFailed(error.localizedDescription)
        }
    }

    private static func _code(of finding: TweakCompatibility.Finding) -> String {
        "\(finding.code)"
    }

    private static func _observedLayout(hasRoot: Bool, hasRootless: Bool) -> TweakPackageLayout? {
        switch (hasRoot, hasRootless) {
        case (true, true): return .mixed
        case (false, true): return .rootless
        case (true, false): return .rootful
        case (false, false): return nil
        }
    }

    private static func _locateControlFile(in root: URL, fileManager: FileManager) throws -> URL {
        let candidates = try _listFiles(in: root, fileManager: fileManager).map(\.url)
        guard let control = candidates.first(where: { $0.lastPathComponent == "control" }) else {
            throw TweakPackageInspectorError.missingControl
        }
        return control
    }

    private static func _parseControl(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        var currentKey: String?
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix(" "), let currentKey {
                fields[currentKey, default: ""] += "\n" + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            fields[key] = value
            currentKey = key
        }
        return fields
    }

    private struct Entry {
        let url: URL
        let path: String
    }

    private static func _listFiles(in root: URL, fileManager: FileManager) throws -> [Entry] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [Entry] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(standardized.path.dropFirst(rootPath.count + 1))
            guard !relative.isEmpty else { continue }
            result.append(Entry(url: standardized, path: relative))
        }
        return result
    }

    private static func _readFilters(
        in entries: [Entry],
        binaryNames: [String]
    ) -> ([String: TweakFilterMetadata], [String]) {
        var filters: [String: TweakFilterMetadata] = [:]
        var errors: [String] = []
        for entry in entries where entry.url.pathExtension.lowercased() == "plist" {
            let parsed: Any
            do {
                parsed = try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: entry.url), options: [], format: nil
                )
            } catch {
                errors.append(String.localized("A tweak filter plist could not be parsed: %@", arguments: entry.path))
                continue
            }
            guard let object = parsed as? [String: Any] else {
                errors.append(String.localized("A tweak filter plist is not a dictionary: %@", arguments: entry.path))
                continue
            }
            let filterObject = object["Filter"] as? [String: Any] ?? object
            let bundles = _rules(from: filterObject["Bundles"], kind: .bundle)
            let executables = _rules(from: filterObject["Executables"], kind: .executable)
            let invalid = bundles.invalid + executables.invalid
            if invalid.isEmpty {
                let key = binaryNames.first { entry.path.contains($0) } ?? entry.path
                filters[key] = TweakFilterMetadata(bundles: bundles.valid, executables: executables.valid)
            } else {
                errors.append(String.localized(
                    "A tweak filter in %@ has invalid rules: %@", arguments: entry.path, invalid.joined(separator: ", ")
                ))
            }
        }
        return (filters, errors)
    }

    private static func _rules(from value: Any?, kind: InjectionFilterRule.Kind) -> (valid: [InjectionFilterRule], invalid: [String]) {
        let values: [Any]
        if let array = value as? [Any] { values = array }
        else if let string = value as? String { values = [string] }
        else if value == nil { return ([], []) }
        else { return ([], ["expected an array of identifiers"]) }

        var valid: [InjectionFilterRule] = []
        var invalid: [String] = []
        for item in values {
            guard let text = item as? String else { invalid.append("non-string value"); continue }
            if let error = InjectionFilterRule.validate(pattern: text) { invalid.append(error.description); continue }
            valid.append(InjectionFilterRule(kind: kind, pattern: text))
        }
        return (valid, invalid)
    }
}
