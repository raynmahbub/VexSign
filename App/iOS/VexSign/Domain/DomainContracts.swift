import Foundation

// MARK: - Domain Errors

/// Pure domain failures across VexSign architectural boundaries, free of UIKit/SwiftUI/Vendor types.
enum ArchitectureDomainError: Error, Equatable, Sendable {
    case invalidURL(String)
    case unsupportedScheme(String)
    case insecureTransport(String)
    case redirectBlocked
    case httpError(statusCode: Int)
    case transferSizeExceeded(limitBytes: Int64)
    case emptyDownloadPayload
    case unsafeCallbackTemplate
    case missingCertificateMaterial
    case duplicateOrBusyOperation
    case importFailed(String)
    case resetFailed(String)
}

extension ArchitectureDomainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid URL: \(value)"
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme: \(scheme)"
        case .insecureTransport(let detail):
            return detail
        case .redirectBlocked:
            return "The download attempted an unsafe redirect and was blocked."
        case .httpError(let statusCode):
            return "Server returned HTTP \(statusCode)."
        case .transferSizeExceeded(let limitBytes):
            return "Download exceeded the \(limitBytes) byte safety limit."
        case .emptyDownloadPayload:
            return "The downloaded file was empty."
        case .unsafeCallbackTemplate:
            return "Rejected certificate export callback with an unsafe URL scheme."
        case .missingCertificateMaterial:
            return "Missing certificate or provisioning profile data."
        case .duplicateOrBusyOperation:
            return "An equivalent operation is already in progress."
        case .importFailed(let reason):
            return reason
        case .resetFailed(let reason):
            return reason
        }
    }
}

// MARK: - Workspace Routes & Deep-Link Parsing

/// Pure workspace destination identifiers decoded from `vexsign://` / `feather://` URLs.
enum WorkspaceDestination: String, Equatable, Sendable, CaseIterable {
    case home
    case apps
    case files
    case signedApps
    case appStore
    case downloads
    case tasks
    case logs
    case settings

    static func resolve(host: String) -> Self? {
        switch host.lowercased() {
        case "home": return .home
        case "library": return .apps
        case "files": return .files
        case "signed", "signedapps": return .signedApps
        case "appstore": return .appStore
        case "activity", "downloads": return .downloads
        case "tasks": return .tasks
        case "logs": return .logs
        case "settings": return .settings
        default: return nil
        }
    }
}

/// Pure representation of an incoming deep link or file share passed to VexSign.
enum DeepLinkCommand: Equatable, Sendable {
    case importCertificate(p12Base64: String, provisionBase64: String, password: String)
    case invalidCertificateImport
    case exportCertificate(callbackTemplate: String)
    case addTweakRepository(URL)
    case openRepositoryApp(appID: String, appName: String?, sourceIdentifier: String?)
    case openWorkspace(WorkspaceDestination)
    case launchApp(bundleIdentifier: String)
    case addSource(String)
    case downloadAndInstall(URL, notifyDirectStarted: Bool)
    case importPackageFile(URL)
    case importTweakFile(URL)
    case unsupported

    private static let customAppSchemes: Set<String> = ["vexsign", "feather"]
    private static let packageExtensions: Set<String> = ["ipa", "tipa"]
    private static let tweakExtensions: Set<String> = ["dylib", "deb", "framework", "bundle", "zip"]

    /// Pure deterministic parser — unit-testable without UIApplication, SwiftUI, or CoreData.
    static func parse(_ url: URL) -> DeepLinkCommand {
        let scheme = url.scheme?.lowercased() ?? ""
        if customAppSchemes.contains(scheme) {
            return parseCustomSchemeURL(url)
        }

        let ext = url.pathExtension.lowercased()
        if packageExtensions.contains(ext) {
            return .importPackageFile(url)
        }
        if tweakExtensions.contains(ext) {
            return .importTweakFile(url)
        }
        return .unsupported
    }

    private static func parseCustomSchemeURL(_ url: URL) -> DeepLinkCommand {
        let host = url.host?.lowercased() ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ name: String, caseInsensitive: Bool = false) -> String? {
            if caseInsensitive {
                return queryItems.first(where: { $0.name.lowercased() == name.lowercased() })?.value
            }
            return queryItems.first(where: { $0.name == name })?.value
        }

        if host == "import-certificate" {
            guard
                let p12Base64 = queryValue("p12")?.removingPercentEncoding,
                let provisionBase64 = queryValue("mobileprovision")?.removingPercentEncoding,
                let passwordBase64 = queryValue("password")?.removingPercentEncoding,
                let passwordData = Data(base64Encoded: passwordBase64),
                let password = String(data: passwordData, encoding: .utf8)
            else {
                return .invalidCertificateImport
            }
            return .importCertificate(
                p12Base64: p12Base64,
                provisionBase64: provisionBase64,
                password: password
            )
        }

        if host == "export-certificate" {
            let lowered = queryItems.reduce(into: [String: String]()) { result, item in
                result[item.name.lowercased()] = item.value
            }
            guard let template = lowered["callback_template"]?.removingPercentEncoding else {
                return .unsupported
            }
            return .exportCertificate(callbackTemplate: template)
        }

        if host == "tweak-repository" || url.path.hasPrefix("/tweak-repository") {
            let raw = queryValue("url", caseInsensitive: true)
                ?? httpsURLSuffix(in: url, marker: "/tweak-repository/")
            if let raw,
               let repoURL = URL(string: raw),
               repoURL.scheme?.lowercased() == "https",
               repoURL.host != nil {
                return .addTweakRepository(repoURL)
            }
            return .unsupported
        }

        if host == "repo-app" {
            if let appID = queryValue("id"), !appID.isEmpty {
                return .openRepositoryApp(
                    appID: appID,
                    appName: queryValue("name"),
                    sourceIdentifier: queryValue("source")
                )
            }
            return .unsupported
        }

        if host == "launch" {
            let candidate = (
                queryValue("bundleId", caseInsensitive: true)
                    ?? queryValue("bundleIdentifier", caseInsensitive: true)
                    ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !candidate.isEmpty,
                  !candidate.contains("/"),
                  candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            else {
                return .unsupported
            }
            return .launchApp(bundleIdentifier: candidate)
        }

        if let destination = WorkspaceDestination.resolve(host: host) {
            return .openWorkspace(destination)
        }

        if host == "direct-install" || host == "install" || url.path.hasPrefix("/direct-install") {
            let targetString = queryValue("url", caseInsensitive: true)
                ?? httpsURLSuffix(in: url, marker: "/direct-install/")
                ?? httpsURLSuffix(in: url, marker: "/install/")
            if let targetString, let downloadURL = URL(string: targetString) {
                return .downloadAndInstall(downloadURL, notifyDirectStarted: host == "direct-install" || url.path.hasPrefix("/direct-install"))
            }
            return .unsupported
        }

        if let sourcePath = httpsURLSuffix(in: url, marker: "/source/") {
            return .addSource(sourcePath)
        }

        if let installPath = httpsURLSuffix(in: url, marker: "/install/"),
           let downloadURL = URL(string: installPath) {
            return .downloadAndInstall(downloadURL, notifyDirectStarted: false)
        }

        return .unsupported
    }

    private static func httpsURLSuffix(in url: URL, marker: String) -> String? {
        let raw = url.absoluteString
        guard let range = raw.range(of: marker) else { return nil }
        let suffix = String(raw[range.upperBound...])
        let decoded = suffix.removingPercentEncoding ?? suffix
        if decoded.hasPrefix("https://") {
            return decoded
        }
        guard suffix.hasPrefix("https://") else { return nil }
        return suffix
    }
}

// MARK: - Reset & Diagnostics Value Types

enum WorkspaceResetScope: Equatable, Sendable {
    case workCache
    case networkCache
    case sources
    case signedApps
    case importedApps
    case tweaks
    case certificates(resetAll: Bool)
    case userDefaults
    case all
}

struct WorkspaceCountsSummary: Equatable, Sendable {
    let networkCacheSizeFormatted: String
    let sourcesCountText: String
    let signedAppsCountText: String
    let importedAppsCountText: String
    let tweaksCount: Int
    let certificatesCountText: String
}

enum DirectInstallMode: String, CaseIterable, Identifiable, Sendable {
    case signAndInstall
    case installWithoutSigning

    var id: String { rawValue }
}

enum DirectInstallResult: Equatable, Sendable {
    case queuedForDownloadAndSign
    case installedAsContainerGuest
    case installedDirectly
    case needsIssueConfirmation([String])
}

struct DownloadedFileItem: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let name: String
    let url: URL
    let size: Int64
    let date: Date
}

struct CertificateSummaryItem: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let expiration: Date?
    let daysRemaining: Int?
    let isExpiringSoon: Bool
    let isRevoked: Bool
}

struct DiagnosticSourceStatus: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let hasError: Bool
    let isStale: Bool
}

struct DiagnosticTaskSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let iconName: String
    let phaseTitle: String
    let isFailed: Bool
}

struct DiagnosticOverviewSnapshot: Equatable, Sendable {
    let migrationWarnings: [String]
    let certificateCount: Int
    let expiringCertificateCount: Int
    let repositoryCount: Int
    let failingRepositoryCount: Int
    let staleSourceCount: Int
    let certificates: [CertificateSummaryItem]
    let failingSourceNames: [String]
    let recentTasks: [DiagnosticTaskSummary]
}

struct AppPrivacyItem: Identifiable, Equatable, Sendable {
    let id: String
    let uuid: String
    let name: String
    let identifier: String
    let version: String
    let isSigned: Bool
    let isLocked: Bool
    let isHidden: Bool
    let bundleURL: URL?
}

struct CertificateOptionItem: Identifiable, Equatable, Sendable {
    let id: String
    let tagName: String
    let displayName: String
}

struct FirmwareDeviceRecord: Identifiable, Hashable, Sendable {
    let name: String
    let identifier: String
    let boardConfig: String?
    let platform: String?

    var id: String { identifier }
}

struct FirmwareBuildRecord: Identifiable, Hashable, Sendable {
    let identifier: String
    let version: String
    let buildID: String
    let fileSize: Int64?
    let downloadURL: URL?
    let isStillSigned: Bool
    let formattedSize: String
    let filename: String

    var id: String { "\(identifier)-\(buildID)" }
}
