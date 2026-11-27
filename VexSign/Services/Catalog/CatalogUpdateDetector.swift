// MARK: - Catalog-based update detection
//
// Updates are decided from an installed app's real bundle identifier and
// version against releases published by a configured source. Missing or
// unorderable versions fail closed; a reachable catalog alone is not a claim
// that an update is compatible with this device or signing identity.

import Foundation
import NimbleExtensions

struct CatalogInstalledApp: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String
    let version: String?
    let sourceURL: String?
    let recordID: String?
}

enum CatalogUpdateDetector {
    static func detect(
        installed: [CatalogInstalledApp],
        apps: [CatalogAppRecord],
        currentOSVersion: String?,
        signingIdentityAvailable: Bool
    ) -> [CatalogUpdateCandidate] {
        let index = Dictionary(grouping: installed) { CatalogIdentity.bundleKey($0.bundleIdentifier) }
            .compactMapValues(\.first)
        var candidates: [CatalogUpdateCandidate] = []

        for app in apps {
            guard let key = CatalogIdentity.bundleKey(app.bundleIdentifier),
                  let installedApp = index[key] else { continue }
            guard let release = app.latest else {
                candidates.append(candidate(
                    app: app, release: nil, installed: installedApp,
                    verdict: .noDownload, reason: .localized("The selected source has no downloadable release.")
                ))
                continue
            }
            guard let installedVersion = installedApp.version, !installedVersion.isEmpty else {
                candidates.append(candidate(
                    app: app, release: release, installed: installedApp,
                    verdict: .unknownVersion, reason: .localized("The installed version is unknown; no update was offered.")
                ))
                continue
            }
            guard let order = VersionOrder.precedence(release.version, installedVersion) else {
                candidates.append(candidate(
                    app: app, release: release, installed: installedApp,
                    verdict: .unknownVersion, reason: .localized("One of the versions cannot be compared safely.")
                ))
                continue
            }
            if let identity = installedApp.sourceURL, !identity.isEmpty,
               !CatalogIdentity.isSameSource(identity, app.sourceURL) {
                // A different publisher can legitimately ship the same bundle id.
                // Do not silently replace an installed app with it.
                candidates.append(candidate(
                    app: app, release: release, installed: installedApp,
                    verdict: .incompatible, reason: .localized("The installed copy came from a different source.")
                ))
                continue
            }
            if let minimum = release.minimumOSVersion, let current = currentOSVersion,
               let comparison = VersionOrder.precedence(minimum, current),
               comparison == .orderedDescending {
                candidates.append(candidate(
                    app: app, release: release, installed: installedApp,
                    verdict: .incompatible, reason: .localized("This release needs a newer iOS version.")
                ))
                continue
            }
            guard signingIdentityAvailable else {
                candidates.append(candidate(
                    app: app, release: release, installed: installedApp,
                    verdict: .incompatible, reason: .localized("No usable signing identity is available for this update.")
                ))
                continue
            }

            switch order {
            case .orderedDescending:
                candidates.append(candidate(app: app, release: release, installed: installedApp, verdict: .updateAvailable, reason: nil))
            case .orderedSame:
                candidates.append(candidate(app: app, release: release, installed: installedApp, verdict: .upToDate, reason: nil))
            case .orderedAscending:
                candidates.append(candidate(app: app, release: release, installed: installedApp, verdict: .olderVersion, reason: nil))
            }
        }
        return candidates.sorted {
            ($0.verdict == .updateAvailable && $1.verdict != .updateAvailable)
                || ($0.verdict == .updateAvailable && $1.verdict == .updateAvailable && $0.installedName.localizedCaseInsensitiveCompare($1.installedName) == .orderedAscending)
        }
    }

    private static func candidate(
        app: CatalogAppRecord,
        release: CatalogRelease?,
        installed: CatalogInstalledApp,
        verdict: CatalogUpdateVerdict,
        reason: String?
    ) -> CatalogUpdateCandidate {
        let fallback = CatalogRelease(
            version: "", date: nil, downloadURL: "", size: nil, sha256: nil,
            changelog: nil, minimumOSVersion: nil, supportedDevices: [], installName: nil
        )
        return CatalogUpdateCandidate(
            bundleIdentifier: app.bundleIdentifier,
            installedName: installed.name,
            installedVersion: installed.version,
            app: app,
            release: release ?? fallback,
            verdict: verdict,
            reason: reason
        )
    }
}
