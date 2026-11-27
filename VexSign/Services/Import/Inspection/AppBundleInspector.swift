// Read-only application bundle inspection.
//
// The importer already validates archive safety and finds the one top-level app
// before it reaches the library. This inspector runs on that validated bundle
// and produces a bounded, typed record of the metadata, nested bundles,
// executables and existing signing assets. It never executes imported code,
// modifies the bundle, or claims cryptographic signature verification.

import Foundation
import IDeviceSwift
import NimbleExtensions

enum AppBundleInspector {
    private static let maximumInfoBytes = 2 * 1024 * 1024
    private static let maximumExecutableBytes: UInt64 = 512 * 1024 * 1024
    private static let maximumDirectories = 2048
    private static let maximumDepth = 12

    static func inspect(
        appBundle: URL,
        archive: AppBundleInspection.ArchiveSummary? = nil,
        now: Date = Date()
    ) -> AppBundleInspectionResult {
        let root = appBundle.resolvingSymlinksInPath().standardizedFileURL
        var diagnostics: [AppBundleInspection.Diagnostic] = []
        let infoURL = root.appendingPathComponent("Info.plist")
        let plistData = try? CertificateInputReader.read(infoURL, maximumBytes: maximumInfoBytes) // try? ok: absence is reported as a diagnostic below
        var plist: [String: Any] = [:]
        if let plistData {
            do {
                let parsed = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
                guard let dictionary = parsed as? [String: Any] else {
                    diagnostics.append(.init(severity: .error, code: "plist-not-dictionary",
                                             subject: "Info.plist", detail: .localized("The app's Info.plist is not a property-list dictionary.")))
                }
                plist = dictionary
            } catch {
                diagnostics.append(.init(severity: .error, code: "plist-unreadable",
                                         subject: "Info.plist", detail: .localized("The app's Info.plist could not be parsed.")))
            }
        } else {
            diagnostics.append(.init(severity: .error, code: "plist-missing",
                                     subject: "Info.plist", detail: .localized("The app's Info.plist is missing or unreadable.")))
        }

        let identifier = string("CFBundleIdentifier", in: plist)
        if let identifier, !DeviceApplicationInventory.isBundleIdentifier(identifier) {
            diagnostics.append(.init(severity: .error, code: "identifier-invalid",
                                     subject: identifier, detail: .localized("The app's bundle identifier is malformed.")))
        } else if identifier == nil {
            diagnostics.append(.init(severity: .error, code: "identifier-missing",
                                     subject: "CFBundleIdentifier", detail: .localized("The app has no bundle identifier.")))
        }

        let executable = inspectExecutable(in: root, plist: plist, diagnostics: &diagnostics)
        let signature = inspectSignature(in: root, executable: executable, diagnostics: &diagnostics)
        var nested = inspectNestedBundles(in: root, diagnostics: &diagnostics)

        if let identifier {
            let duplicates = nested.filter { $0.bundleIdentifier?.caseInsensitiveCompare(identifier) == .orderedSame }
            if !duplicates.isEmpty {
                diagnostics.append(.init(severity: .warning, code: "duplicate-bundle-identifier",
                                         subject: identifier,
                                         detail: .localized("A nested bundle declares the main app's bundle identifier.")))
            }
        }
        var seenIdentifiers = Set<String>()
        for bundle in nested {
            guard let nestedID = bundle.bundleIdentifier else { continue }
            let key = nestedID.lowercased()
            if !seenIdentifiers.insert(key).inserted {
                diagnostics.append(.init(severity: .warning, code: "nested-identifier-collision",
                                         subject: nestedID,
                                         detail: .localized("Two nested bundles declare the same bundle identifier.")))
            }
        }
        nested.sort { $0.relativePath < $1.relativePath }

        let status: AppBundleInspection.Status
        if diagnostics.contains(where: { $0.severity == .error }) {
            status = .invalid
        } else if nested.contains(where: { $0.diagnostics.contains(where: { $0.severity == .error }) }) {
            status = .incomplete
        } else if diagnostics.contains(where: { $0.code == "nested-identifier-collision" }) {
            status = .ambiguous
        } else if identifier == nil || !executable.exists || !executable.isMachO {
            status = .incomplete
        } else {
            status = .valid
        }

        let report = AppBundleInspection(
            schema: 1,
            inspectedAt: now,
            bundleName: root.lastPathComponent,
            status: status,
            archive: archive,
            identity: .init(bundleIdentifier: identifier,
                            name: string("CFBundleName", in: plist),
                            displayName: string("CFBundleDisplayName", in: plist),
                            executableName: string("CFBundleExecutable", in: plist),
                            packageType: string("CFBundlePackageType", in: plist)),
            version: .init(shortVersion: string("CFBundleShortVersionString", in: plist),
                           build: string("CFBundleVersion", in: plist)),
            platform: .init(minimumOSVersion: string("MinimumOSVersion", in: plist),
                            platformName: string("DTPlatformName", in: plist),
                            platformVersion: string("DTPlatformVersion", in: plist),
                            deviceFamilies: (plist["UIDeviceFamily"] as? [NSNumber])?.map(\.intValue) ?? []),
            presentation: .init(displayName: string("CFBundleDisplayName", in: plist) ?? string("CFBundleName", in: plist),
                                iconFiles: iconFiles(in: plist),
                                iconFile: string("CFBundleIconFile", in: plist),
                                supportedOrientations: strings("UISupportedInterfaceOrientations", in: plist)),
            integration: .init(urlSchemes: urlSchemes(in: plist),
                               documentTypes: documentTypes(in: plist),
                               capabilities: capabilities(in: plist)),
            nestedBundles: nested,
            executable: executable,
            signature: signature,
            diagnostics: diagnostics
        )
        return AppBundleInspectionResult(report: report, originalInfoPlist: plistData)
    }

    // MARK: - Executables

    private static func inspectExecutable(
        in root: URL,
        plist: [String: Any],
        diagnostics: inout [AppBundleInspection.Diagnostic]
    ) -> AppBundleInspection.Executable {
        guard let name = string("CFBundleExecutable", in: plist) else {
            return .init(name: nil, exists: false, isMachO: false, isUniversal: false,
                         architectures: [], minimumOSVersion: nil, platform: nil,
                         isEncrypted: false, hasCodeSignature: false, diagnostics: [])
        }
        guard let url = SigningInputValidation.executable(in: root) else {
            diagnostics.append(.init(severity: .error, code: "executable-missing",
                                     subject: name, detail: .localized("The app's executable is missing or unsafe.")))
            return .init(name: name, exists: false, isMachO: false, isUniversal: false,
                         architectures: [], minimumOSVersion: nil, platform: nil,
                         isEncrypted: false, hasCodeSignature: false, diagnostics: [])
        }
        let (inspection, issues) = machO(at: url, subject: name)
        for issue in issues { diagnostics.append(issue) }
        return .init(name: name, exists: true, isMachO: !inspection.isEmpty,
                     isUniversal: inspection.isUniversal,
                     architectures: inspection.slices.map(\.architecture.description),
                     minimumOSVersion: inspection.deviceNativeSlices.first?.minimumSystemVersion
                        ?? inspection.slices.first?.minimumSystemVersion,
                     platform: inspection.slices.first?.platform,
                     isEncrypted: inspection.isEncrypted,
                     hasCodeSignature: inspection.slices.contains(where: \.hasCodeSignature),
                     diagnostics: issues)
    }

    private static func machO(at url: URL, subject: String)
        -> (MachOInspector.Inspection, [AppBundleInspection.Diagnostic]) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0 // try? ok: unreadable metadata is classified as too large
        guard size > 0, size <= maximumExecutableBytes else {
            return (.empty, [.init(severity: .warning, code: "executable-too-large", subject: subject,
                                   detail: .localized("The executable exceeds the safe inspection size and was not parsed."))])
        }
        let inspection = MachOInspector.inspect(fileAt: url)
        var diagnostics: [AppBundleInspection.Diagnostic] = []
        for issue in inspection.issues {
            let code: String
            let severity: AppBundleInspection.Severity
            switch issue {
            case .notMachO, .truncatedHeader, .truncatedFatHeader, .malformedLoadCommands, .invalidStringOffset:
                code = "executable-malformed"
                severity = .error
            case .encryptedBinary:
                code = "executable-encrypted"
                severity = .warning
            case .unsupportedArchitecture, .noDeviceNativeSlice:
                code = "executable-architecture"
                severity = .warning
            default:
                code = "executable-note"
                severity = .info
            }
            diagnostics.append(.init(severity: severity, code: code, subject: subject,
                                     detail: String(describing: issue)))
        }
        return (inspection, diagnostics)
    }

    // MARK: - Nested bundles

    private static func inspectNestedBundles(
        in root: URL,
        diagnostics: inout [AppBundleInspection.Diagnostic]
    ) -> [AppBundleInspection.NestedBundle] {
        let manager = FileManager.default
        var found: [AppBundleInspection.NestedBundle] = []
        var stack: [(url: URL, depth: Int)] = [(root, 0)]
        var visited = 0

        while let current = stack.popLast() {
            guard visited < maximumDirectories else {
                diagnostics.append(.init(severity: .warning, code: "nested-limit", subject: nil,
                                         detail: .localized("The app contains too many nested directories to inspect completely.")))
                break
            }
            visited += 1
            let entries: [URL]
            do {
                entries = try manager.contentsOfDirectory(
                    at: current.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                diagnostics.append(.init(severity: .warning, code: "nested-unreadable",
                                         subject: relative(current.url, to: root),
                                         detail: .localized("A nested directory could not be read.")))
                continue
            }

            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]) // try? ok: unreadable entry is skipped, not guessed
                if values?.isSymbolicLink == true { continue }
                let isDirectory = values?.isDirectory == true
                let kind = isDirectory ? bundleKind(for: entry) : nil
                if let kind {
                    found.append(inspectNested(entry, kind: kind, root: root))
                    continue // Nested bundle contents are not separate candidates.
                }
                if !isDirectory, entry.pathExtension.lowercased() == "dylib" {
                    found.append(inspectDynamicLibrary(entry, root: root))
                }
                if isDirectory, current.depth < maximumDepth {
                    stack.append((entry, current.depth + 1))
                }
            }
        }
        return found
    }

    private static func bundleKind(for url: URL) -> AppBundleInspection.NestedKind? {
        switch url.pathExtension.lowercased() {
        case "appex": return .appExtension
        case "watchapp": return .watchApplication
        case "framework": return .framework
        case "bundle": return .bundle
        case "plugin": return .plugIn
        case "app":
            return url.deletingLastPathComponent().lastPathComponent.lowercased() == "watch"
                ? .watchApplication : .unsupported
        default: return nil
        }
    }

    private static func inspectNested(
        _ url: URL,
        kind: AppBundleInspection.NestedKind,
        root: URL
    ) -> AppBundleInspection.NestedBundle {
        var nestedDiagnostics: [AppBundleInspection.Diagnostic] = []
        let plistURL = url.appendingPathComponent("Info.plist")
        let hasInfo = FileManager.default.fileExists(atPath: plistURL.path)
        var plist: [String: Any] = [:]
        if hasInfo, let data = try? CertificateInputReader.read(plistURL, maximumBytes: maximumInfoBytes) { // try? ok: unreadable nested plist is diagnosed below
            do {
                plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
            } catch {
                nestedDiagnostics.append(.init(severity: .warning, code: "nested-plist-unreadable",
                                               subject: relative(url, to: root),
                                               detail: .localized("A nested bundle's Info.plist could not be parsed.")))
            }
        } else if hasInfo {
            nestedDiagnostics.append(.init(severity: .warning, code: "nested-plist-unreadable",
                                           subject: relative(url, to: root),
                                           detail: .localized("A nested bundle's Info.plist could not be read.")))
        }
        var architectures: [String] = []
        var hasExecutable = false
        if let executable = SigningInputValidation.executable(in: url) {
            hasExecutable = true
            let (inspection, issues) = machO(at: executable, subject: relative(url, to: root))
            architectures = inspection.slices.map(\.architecture.description)
            nestedDiagnostics.append(contentsOf: issues)
        } else if kind != .bundle {
            nestedDiagnostics.append(.init(severity: .warning, code: "nested-executable-missing",
                                           subject: relative(url, to: root),
                                           detail: .localized("A nested bundle has no readable executable.")))
        }
        return .init(relativePath: relative(url, to: root), kind: kind,
                     bundleIdentifier: string("CFBundleIdentifier", in: plist),
                     name: string("CFBundleName", in: plist),
                     executableName: string("CFBundleExecutable", in: plist),
                     architectures: architectures, hasInfoPlist: hasInfo,
                     hasExecutable: hasExecutable, diagnostics: nestedDiagnostics)
    }

    private static func inspectDynamicLibrary(_ url: URL, root: URL) -> AppBundleInspection.NestedBundle {
        var issues: [AppBundleInspection.Diagnostic] = []
        let (inspection, diagnostics) = machO(at: url, subject: relative(url, to: root))
        issues.append(contentsOf: diagnostics)
        return .init(relativePath: relative(url, to: root), kind: .dynamicLibrary,
                     bundleIdentifier: nil, name: nil, executableName: url.lastPathComponent,
                     architectures: inspection.slices.map(\.architecture.description),
                     hasInfoPlist: false, hasExecutable: !inspection.isEmpty, diagnostics: issues)
    }

    // MARK: - Existing signature

    private static func inspectSignature(
        in root: URL,
        executable: AppBundleInspection.Executable,
        diagnostics: inout [AppBundleInspection.Diagnostic]
    ) -> AppBundleInspection.ExistingSignature {
        let signatureDirectory = root.appendingPathComponent("_CodeSignature")
        var isDirectory: ObjCBool = false
        let hasDirectory = FileManager.default.fileExists(atPath: signatureDirectory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let resources = signatureDirectory.appendingPathComponent("CodeResources")
        let hasResources = FileManager.default.fileExists(atPath: resources.path)

        if hasDirectory, !hasResources {
            diagnostics.append(.init(severity: .error, code: "signature-incomplete",
                                     subject: "_CodeSignature",
                                     detail: .localized("The app has a signature directory but no CodeResources seal.")))
        }

        let profileURL = root.appendingPathComponent("embedded.mobileprovision")
        let profilePresent = FileManager.default.fileExists(atPath: profileURL.path)
        var profileReadable = false
        var profileExpired = false
        var profileUUID: String?
        var profileTeam: String?
        var profileAppID: String?
        var profileExpiry: Date?
        if profilePresent {
            do {
                let data = try CertificateInputReader.read(profileURL)
                let profile = try ProvisioningProfileParser.parse(data, allowingExpiredForDisplay: true)
                profileReadable = true
                profileUUID = profile.UUID
                profileTeam = profile.TeamIdentifier.first
                profileAppID = profile.Entitlements?["application-identifier"]?.value as? String
                profileExpiry = profile.ExpirationDate
                profileExpired = profile.ExpirationDate <= Date()
                if profileExpired {
                    diagnostics.append(.init(severity: .warning, code: "profile-expired",
                                             subject: profile.UUID,
                                             detail: .localized("The embedded provisioning profile has expired.")))
                }
            } catch {
                diagnostics.append(.init(severity: .warning, code: "profile-unreadable",
                                         subject: "embedded.mobileprovision",
                                         detail: .localized("The embedded provisioning profile is not an authenticated, readable Apple profile.")))
            }
        }

        let status: AppBundleInspection.SignatureStatus
        if hasDirectory && !hasResources {
            status = .invalid
        } else if hasDirectory || executable.hasCodeSignature {
            status = .structuralOnly
        } else if profilePresent {
            status = .unsupported // A profile without a signature is structurally incomplete.
        } else {
            status = .absent
        }

        return .init(status: status, hasSignatureDirectory: hasDirectory,
                     hasCodeResources: hasResources,
                     executableDeclaresSignature: executable.hasCodeSignature,
                     profilePresent: profilePresent, profileReadable: profileReadable,
                     profileExpired: profileExpired, profileUUID: profileUUID,
                     profileTeamIdentifier: profileTeam, profileApplicationIdentifier: profileAppID,
                     profileExpiresAt: profileExpiry,
                     diagnostics: diagnostics.filter {
                         $0.code == "signature-incomplete" || $0.code == "profile-expired"
                            || $0.code == "profile-unreadable"
                     })
    }

    // MARK: - Plist access

    private static func string(_ key: String, in plist: [String: Any]) -> String? {
        guard let value = plist[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func strings(_ key: String, in plist: [String: Any]) -> [String] {
        (plist[key] as? [String]) ?? []
    }

    private static func iconFiles(in plist: [String: Any]) -> [String] {
        var files = strings("CFBundleIconFiles", in: plist)
        if let single = string("CFBundleIconFile", in: plist) { files.append(single) }
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            files.append(contentsOf: strings("CFBundleIconFiles", in: primary))
            if let single = string("CFBundleIconFile", in: primary) { files.append(single) }
        }
        return Array(Set(files)).sorted()
    }

    private static func urlSchemes(in plist: [String: Any]) -> [String] {
        guard let types = plist["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return types.flatMap { strings("CFBundleURLSchemes", in: $0) }
    }

    private static func documentTypes(in plist: [String: Any]) -> [String] {
        guard let types = plist["CFBundleDocumentTypes"] as? [[String: Any]] else { return [] }
        return types.compactMap { string("CFBundleTypeName", in: $0) }
    }

    private static func capabilities(in plist: [String: Any]) -> [String] {
        let booleanKeys = ["UIFileSharingEnabled", "UISupportsDocumentBrowser", "UIBackgroundModes",
                           "CFBundleDeveloperNewsstandContentAvailability", "NFCReaderUsageDescription",
                           "NSFaceIDUsageDescription", "NSCameraUsageDescription", "NSLocationWhenInUseUsageDescription"]
        var found = booleanKeys.filter { plist[$0] != nil }
        found.append(contentsOf: strings("UIBackgroundModes", in: plist).map { "background:\($0)" })
        return Array(Set(found)).sorted()
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        let suffix = String(path.dropFirst(base.count))
        return suffix.isEmpty ? root.lastPathComponent : String(suffix.dropFirst())
    }
}
