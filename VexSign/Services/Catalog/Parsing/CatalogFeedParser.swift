// MARK: - Versioned repository feed parsing
//
// Each supported dialect is parsed by its own version-aware entry point. A feed
// is accepted as a whole or refused as a whole: a partially parsed catalog never
// replaces a last-known-good cache. Unknown fields are preserved as data but are
// never acted on.

import Foundation
import CryptoKit
import NimbleExtensions

enum CatalogParseError: LocalizedError, Equatable {
    case tooLarge
    case malformed(String)
    case unsupportedSchema(Int)
    case invalid(String, [CatalogDiagnostic])

    var diagnostics: [CatalogDiagnostic] {
        switch self {
        case .tooLarge:
            [CatalogDiagnostic(severity: .error, code: "feedTooLarge", message: errorDescription ?? "")]
        case .malformed(let detail):
            [CatalogDiagnostic(severity: .error, code: "malformedFeed", message: detail)]
        case .unsupportedSchema(let version):
            [CatalogDiagnostic(severity: .error, code: "unsupportedSchema", message: "Schema version \(version) is not supported.")]
        case .invalid(_, let diagnostics): diagnostics
        }
    }

    var errorDescription: String? {
        switch self {
        case .tooLarge: .localized("The source catalog exceeds the 16 MB safety limit.")
        case .malformed(let detail): String.localized("The source catalog is malformed: %@", arguments: detail)
        case .unsupportedSchema(let version):
            String.localized("This source uses catalog schema %lld, which VexSign cannot read.", arguments: version)
        case .invalid(let message, _): message
        }
    }
}

enum CatalogFeedParser {
    static let maximumFeedBytes = 16 * 1024 * 1024
    static let maximumApps = 50_000
    static let maximumScreenshots = 40

    // MARK: - Entry points

    /// AltStore/SideStore/Feather `apps` feed. `versions[]` carries release history.
    static func parseAltStoreFamily(
        _ data: Data,
        sourceID: String,
        sourceURL: String,
        format: CatalogSourceFormat,
        fetchedAt: Date = Date()
    ) throws -> CatalogSnapshot {
        try parse(data, sourceID: sourceID, sourceURL: sourceURL, format: format,
                  appsContainerKeys: [["apps"]], fetchedAt: fetchedAt)
    }

    /// ESign feeds may wrap the `apps` array under `data`. Encrypted feeds are
    /// explicitly unsupported here rather than being decoded optimistically.
    static func parseESign(
        _ data: Data,
        sourceID: String,
        sourceURL: String,
        fetchedAt: Date = Date()
    ) throws -> CatalogSnapshot {
        try parse(data, sourceID: sourceID, sourceURL: sourceURL, format: .esign,
                  appsContainerKeys: [["apps"], ["data", "apps"]], fetchedAt: fetchedAt)
    }

    static func parse(
        _ data: Data,
        sourceID: String,
        sourceURL: String,
        format: CatalogSourceFormat,
        fetchedAt: Date = Date()
    ) throws -> CatalogSnapshot {
        switch format {
        case .altStore, .sideStore, .feather, .custom:
            try parseAltStoreFamily(data, sourceID: sourceID, sourceURL: sourceURL, format: format, fetchedAt: fetchedAt)
        case .esign:
            try parseESign(data, sourceID: sourceID, sourceURL: sourceURL, fetchedAt: fetchedAt)
        }
    }

    // MARK: - Shared parser

    private static func parse(
        _ data: Data,
        sourceID: String,
        sourceURL: String,
        format: CatalogSourceFormat,
        appsContainerKeys: [[String]],
        fetchedAt: Date
    ) throws -> CatalogSnapshot {
        guard data.count <= maximumFeedBytes else { throw CatalogParseError.tooLarge }
        let rootValue: RepositoryJSON
        do { rootValue = try JSONDecoder().decode(RepositoryJSON.self, from: data) }
        catch { throw CatalogParseError.malformed(error.localizedDescription) }
        guard case .object(let root) = rootValue else {
            throw CatalogParseError.malformed(.localized("The catalog root must be a JSON object."))
        }

        let schema = try _schemaVersion(in: root, format: format)
        if _isEncrypted(root) {
            throw CatalogParseError.invalid(.localized("Encrypted catalogs are not supported by this parser."), [
                CatalogDiagnostic(severity: .error, code: "encryptedFeed", message: "The feed declares encryption.", property: "encrypted")
            ])
        }

        var diagnostics: [CatalogDiagnostic] = []
        let appsValue = appsContainerKeys.lazy.compactMap { _value(for: $0, in: root) }.first
        guard let appsValue, case .array(let rows) = appsValue else {
            throw CatalogParseError.malformed(.localized("The catalog has no apps array."))
        }
        guard rows.count <= maximumApps else {
            throw CatalogParseError.invalid(.localized("The catalog has too many applications."), [
                CatalogDiagnostic(severity: .error, code: "tooManyApps", message: "More than \(maximumApps) apps were declared.", property: "apps")
            ])
        }

        let sourceName = _string(root, "name") ?? _string(root, "sourceName")
        let apps = try rows.enumerated().map { index, row -> CatalogAppRecord in
            guard case .object(let fields) = row else {
                diagnostics.append(CatalogDiagnostic(
                    severity: .error, code: "appNotObject",
                    message: String.localized("App %lld is not a JSON object.", arguments: index + 1),
                    property: "apps[\(index)]"
                ))
                throw CatalogParseError.invalid(.localized("Every catalog app must be an object."), diagnostics)
            }
            return try _app(
                fields,
                index: index,
                sourceID: sourceID,
                sourceName: sourceName ?? sourceURL,
                sourceURL: sourceURL,
                fetchedAt: fetchedAt,
                diagnostics: &diagnostics
            )
        }

        var seenBundles: Set<String> = []
        for (index, app) in apps.enumerated() {
            guard let key = CatalogIdentity.bundleKey(app.bundleIdentifier) else {
                diagnostics.append(CatalogDiagnostic(
                    severity: .error, code: "missingBundleIdentifier",
                    message: String.localized("%@ has no usable bundle identifier.", arguments: app.name),
                    property: "apps[\(index)].bundleIdentifier"
                ))
                continue
            }
            if !seenBundles.insert(key).inserted {
                diagnostics.append(CatalogDiagnostic(
                    severity: .error, code: "duplicateBundleIdentifier",
                    message: String.localized("%@ lists the bundle identifier %@ more than once.", arguments: app.name, app.bundleIdentifier),
                    property: "apps[\(index)].bundleIdentifier"
                ))
            }
        }

        let errors = diagnostics.filter { $0.severity == .error }
        if !errors.isEmpty {
            throw CatalogParseError.invalid(errors.first?.message ?? .localized("The catalog is invalid."), diagnostics)
        }
        guard let name = sourceName, !name.isEmpty else {
            throw CatalogParseError.invalid(.localized("The catalog has no source name."), diagnostics)
        }

        return CatalogSnapshot(
            sourceID: sourceID,
            format: format,
            schemaVersion: schema,
            fetchedAt: fetchedAt,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            name: name,
            summary: _string(root, "description") ?? _string(root, "subtitle"),
            artworkURL: _string(root, "iconURL") ?? _string(root, "headerURL"),
            apps: apps,
            diagnostics: diagnostics
        )
    }

    // MARK: - Fields

    private static func _app(
        _ fields: [String: RepositoryJSON],
        index: Int,
        sourceID: String,
        sourceName: String,
        sourceURL: String,
        fetchedAt: Date,
        diagnostics: inout [CatalogDiagnostic]
    ) throws -> CatalogAppRecord {
        let name = _string(fields, "name") ?? ""
        let bundle = _string(fields, "bundleIdentifier") ?? _string(fields, "bundleID") ?? ""
        let label = name.isEmpty ? "app \(index + 1)" : name
        guard !name.isEmpty, CatalogIdentity.isWellFormed(bundleIdentifier: bundle) else {
            let diagnostic = CatalogDiagnostic(
                severity: .error, code: "missingRequiredAppField",
                message: String.localized("%@ has no name or valid bundle identifier.", arguments: label),
                property: "apps[\(index)]"
            )
            diagnostics.append(diagnostic)
            throw CatalogParseError.invalid(diagnostic.message, diagnostics)
        }

        var releases: [CatalogRelease] = []
        if case .array(let versions) = fields["versions"] {
            for (versionIndex, value) in versions.enumerated() {
                guard case .object(let versionFields) = value else {
                    diagnostics.append(CatalogDiagnostic(
                        severity: .error, code: "invalidVersion",
                        message: String.localized("%@ has a malformed version record.", arguments: label),
                        property: "apps[\(index)].versions[\(versionIndex)]"
                    ))
                    continue
                }
                guard let release = _release(versionFields, label: label, index: index, diagnostics: &diagnostics) else { continue }
                if !releases.contains(release) { releases.append(release) }
            }
        }
        if releases.isEmpty, let release = _release(fields, label: label, index: index, diagnostics: &diagnostics) {
            releases.append(release)
        }
        releases.sort { VersionOrder.isOrderedBefore($0.version, $1.version) }
        guard !releases.isEmpty else {
            let diagnostic = CatalogDiagnostic(
                severity: .error, code: "missingDownload",
                message: String.localized("%@ has no usable download URL.", arguments: label),
                property: "apps[\(index)]"
            )
            diagnostics.append(diagnostic)
            throw CatalogParseError.invalid(diagnostic.message, diagnostics)
        }

        let screenshotValues = _array(fields, "screenshotURLs") ?? _array(fields, "screenshots") ?? []
        guard screenshotValues.count <= maximumScreenshots else {
            let diagnostic = CatalogDiagnostic(
                severity: .error, code: "tooManyScreenshots",
                message: String.localized("%@ declares too many screenshots.", arguments: label),
                property: "apps[\(index)].screenshotURLs"
            )
            diagnostics.append(diagnostic)
            throw CatalogParseError.invalid(diagnostic.message, diagnostics)
        }
        var screenshots: [String] = []
        for value in screenshotValues {
            guard case .string(let url) = value else {
                diagnostics.append(CatalogDiagnostic(
                    severity: .warning, code: "nonStringScreenshot",
                    message: String.localized("%@ has a screenshot that is not a URL.", arguments: label),
                    property: "apps[\(index)].screenshotURLs"
                ))
                continue
            }
            if let accepted = _webURL(url, property: "apps[\(index)].screenshotURLs", label: label, diagnostics: &diagnostics) {
                screenshots.append(accepted)
            }
        }

        let icon = _string(fields, "iconURL") ?? _string(fields, "icon")
        let validatedIcon = icon.flatMap {
            _webURL($0, property: "apps[\(index)].iconURL", label: label, diagnostics: &diagnostics)
        }
        if icon != nil && validatedIcon == nil {
            diagnostics.append(CatalogDiagnostic(
                severity: .warning, code: "missingIcon",
                message: String.localized("%@ has no usable icon URL.", arguments: label),
                property: "apps[\(index)].iconURL"
            ))
        }

        let permissions = (_array(fields, "appPermissions") ?? _array(fields, "permissions") ?? []).flatMap { value -> [String] in
            if case .string(let text) = value { return [text] }
            if case .object(let object) = value { return object.keys.sorted() }
            return []
        }

        var extra = fields
        for key in ["name", "bundleIdentifier", "bundleID", "version", "versionDate", "date", "downloadURL", "download",
                    "localizedDescription", "description", "iconURL", "icon", "developerName", "developer", "category",
                    "tintColor", "size", "screenshotURLs", "screenshots", "versions", "appPermissions", "permissions",
                    "minimumOSVersion", "deviceFamilies", "sha256"] {
            extra.removeValue(forKey: key)
        }

        return CatalogAppRecord(
            id: CatalogIdentity.appID(source: sourceURL, bundleIdentifier: bundle) ?? "\(sourceID)#\(index)",
            sourceID: sourceID,
            sourceName: sourceName,
            sourceURL: sourceURL,
            bundleIdentifier: bundle,
            name: name,
            developer: _string(fields, "developerName") ?? _string(fields, "developer"),
            summary: _string(fields, "subtitle"),
            description: _string(fields, "localizedDescription") ?? _string(fields, "description"),
            iconURL: validatedIcon,
            screenshotURLs: screenshots,
            category: _string(fields, "category"),
            tintColor: _string(fields, "tintColor"),
            releases: releases,
            permissions: permissions,
            extra: extra,
            fetchedAt: fetchedAt,
            metadataIsVerified: false
        )
    }

    private static func _release(
        _ fields: [String: RepositoryJSON],
        label: String,
        index: Int,
        diagnostics: inout [CatalogDiagnostic]
    ) -> CatalogRelease? {
        let version = _string(fields, "version") ?? ""
        let rawURL = _string(fields, "downloadURL") ?? _string(fields, "download") ?? ""
        guard !version.isEmpty,
              let url = _webURL(rawURL, property: "apps[\(index)].downloadURL", label: label, diagnostics: &diagnostics) else {
            return nil
        }
        let size: Int64? = {
            guard let number = _number(fields, "size"), number >= 0, number < Double(Int64.max) else { return nil }
            return Int64(number)
        }()
        let hash = _string(fields, "sha256") ?? _string(fields, "checksum")
        let devices = (_array(fields, "deviceFamilies") ?? _array(fields, "supportedDevices") ?? []).compactMap { value in
            if case .string(let text) = value { return text }
            return nil
        }
        return CatalogRelease(
            version: version,
            date: _string(fields, "date") ?? _string(fields, "versionDate"),
            downloadURL: url,
            size: size,
            sha256: _normalizedHash(hash),
            changelog: _string(fields, "changelog") ?? _string(fields, "releaseNotes"),
            minimumOSVersion: _string(fields, "minimumOSVersion") ?? _string(fields, "minOSVersion"),
            supportedDevices: devices,
            installName: _string(fields, "bundleIdentifier") ?? _string(fields, "bundleID")
        )
    }

    // MARK: - Helpers

    private static func _schemaVersion(in root: [String: RepositoryJSON], format: CatalogSourceFormat) throws -> Int {
        let raw = _string(root, "schemaVersion") ?? _string(root, "schema")
            ?? _number(root, "schemaVersion").flatMap { Int($0) }.map(String.init) ?? "1"
        guard let version = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CatalogParseError.malformed(.localized("The catalog schema version is not a number."))
        }
        guard format.supportedSchemaVersions.contains(version) else {
            throw CatalogParseError.unsupportedSchema(version)
        }
        return version
    }

    private static func _isEncrypted(_ root: [String: RepositoryJSON]) -> Bool {
        if case .bool(let flag) = root["encrypted"], flag { return true }
        if case .object(let userInfo) = root["userInfo"], case .bool(let flag) = userInfo["encrypted"], flag { return true }
        return false
    }

    private static func _value(for path: [String], in root: [String: RepositoryJSON]) -> RepositoryJSON? {
        var current: RepositoryJSON = .object(root)
        for key in path {
            guard case .object(let object) = current, let next = object[key] else { return nil }
            current = next
        }
        return current
    }

    private static func _string(_ fields: [String: RepositoryJSON], _ key: String) -> String? {
        guard case .string(let value) = fields[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func _number(_ fields: [String: RepositoryJSON], _ key: String) -> Double? {
        guard case .number(let value) = fields[key] else { return nil }
        return value
    }

    private static func _array(_ fields: [String: RepositoryJSON], _ key: String) -> [RepositoryJSON]? {
        guard case .array(let value) = fields[key] else { return nil }
        return value
    }

    private static func _webURL(
        _ raw: String,
        property: String,
        label: String,
        diagnostics: inout [CatalogDiagnostic]
    ) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = RepositoryValidator.webURL(trimmed), url.user == nil, url.password == nil else {
            diagnostics.append(CatalogDiagnostic(
                severity: .error, code: "unsafeURL",
                message: String.localized("%@ declares an unsafe URL for %@.", arguments: label, property),
                property: property
            ))
            return nil
        }
        if url.scheme?.lowercased() == "http" {
            guard SourceURLPolicy.allowInsecureHTTP, SourceURLPolicy.isLocalNetworkHost(url) else {
                diagnostics.append(CatalogDiagnostic(
                    severity: .error, code: "insecureURL",
                    message: String.localized("%@ declares a public HTTP URL. HTTPS is required.", arguments: label),
                    property: property
                ))
                return nil
            }
        }
        return trimmed
    }

    private static func _normalizedHash(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value
    }
}
