// MARK: - Device-aware catalog update planning
//
// The source catalog already compares versions and source identity. This layer adds the
// constraints only the device can supply: OS version, an admitted installation route, a live
// authorization, published integrity and measurable free space. A newer version is never
// treated as compatible just because its number is larger.

import Foundation
import IDeviceSwift
import NimbleExtensions

enum DeviceUpdateVerdict: String, Equatable, Sendable {
    case updateAvailable, upToDate, downgradeRejected, incompatible, unknown, noInstalledApp
}

struct DeviceUpdatePlan: Equatable, Sendable, Identifiable {
    let bundleIdentifier: String
    let installedName: String
    let installedVersion: String?
    let candidateVersion: String
    let sourceName: String
    let verdict: DeviceUpdateVerdict
    let reason: String
    let download: CatalogDownloadRequest?

    var id: String { bundleIdentifier.lowercased() + "|" + candidateVersion + "|" + sourceName }

    var canDownload: Bool { verdict == .updateAvailable && download != nil }

    var title: String {
        switch verdict {
        case .updateAvailable: .localized("Update available")
        case .upToDate: .localized("Up to date")
        case .downgradeRejected: .localized("Downgrade blocked")
        case .incompatible: .localized("Not compatible")
        case .unknown: .localized("Compatibility unknown")
        case .noInstalledApp: .localized("Not installed")
        }
    }
}

struct DeviceUpdateContext: Sendable {
    let installedApplications: [ManagedInstalledApplication]
    let catalogApps: [CatalogAppRecord]
    let deviceOSVersion: String?
    let capabilities: [StoredDeviceCapability]
    let signingIdentityAvailable: Bool
    let authorizationExpiresAt: Date?
    let availableBytes: Int64?
    let catalogIntegrityVerified: Bool
    let now: Date

    init(
        installedApplications: [ManagedInstalledApplication],
        catalogApps: [CatalogAppRecord],
        deviceOSVersion: String?,
        capabilities: [StoredDeviceCapability],
        signingIdentityAvailable: Bool,
        authorizationExpiresAt: Date? = nil,
        availableBytes: Int64? = nil,
        catalogIntegrityVerified: Bool = false,
        now: Date = Date()
    ) {
        self.installedApplications = installedApplications
        self.catalogApps = catalogApps
        self.deviceOSVersion = deviceOSVersion
        self.capabilities = capabilities
        self.signingIdentityAvailable = signingIdentityAvailable
        self.authorizationExpiresAt = authorizationExpiresAt
        self.availableBytes = availableBytes
        self.catalogIntegrityVerified = catalogIntegrityVerified
        self.now = now
    }
}

enum DeviceUpdatePlanner {
    static func plans(_ context: DeviceUpdateContext) -> [DeviceUpdatePlan] {
        let installed = context.installedApplications.map {
            CatalogInstalledApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier,
                                version: $0.version, sourceURL: nil, recordID: nil)
        }
        let candidates = CatalogUpdateDetector.detect(
            installed: installed, apps: context.catalogApps,
            currentOSVersion: context.deviceOSVersion,
            signingIdentityAvailable: context.signingIdentityAvailable
        )
        return candidates.map { candidate in
            plan(for: candidate, context: context)
        }
        .sorted { lhs, rhs in
            if lhs.verdict == rhs.verdict { return lhs.bundleIdentifier < rhs.bundleIdentifier }
            return lhs.verdict == .updateAvailable
        }
    }

    private static func plan(for candidate: CatalogUpdateCandidate,
                             context: DeviceUpdateContext) -> DeviceUpdatePlan {
        let base = DeviceUpdatePlan(
            bundleIdentifier: candidate.bundleIdentifier,
            installedName: candidate.installedName,
            installedVersion: candidate.installedVersion,
            candidateVersion: candidate.release.version,
            sourceName: candidate.app.sourceName,
            verdict: .incompatible,
            reason: candidate.reason ?? .localized("This release was not accepted."),
            download: nil
        )

        switch candidate.verdict {
        case .olderVersion:
            return with(base, verdict: .downgradeRejected,
                        reason: .localized("The catalog release is older than the installed version. A downgrade was not attempted."))
        case .upToDate:
            return with(base, verdict: .upToDate, reason: .localized("The installed version matches the catalog release."))
        case .incompatible, .noDownload, .installedAppMissing, .unknownVersion:
            return with(base, verdict: candidate.verdict == .unknownVersion ? .unknown : .incompatible,
                        reason: candidate.reason ?? .localized("The release could not be verified as compatible."))
        case .updateAvailable:
            break
        }

        guard context.deviceOSVersion != nil else {
            return with(base, verdict: .unknown,
                        reason: .localized("The device OS version is unknown, so the minimum OS requirement could not be checked."))
        }
        guard context.capabilities.contains(where: { $0.matches(.pairedInstall) && $0.isSupported }) else {
            return with(base, verdict: .incompatible,
                        reason: .localized("This device has no admitted installation route. Use the signed IPA export or a compatible companion."))
        }
        if let expiry = context.authorizationExpiresAt {
            guard expiry > context.now else {
                return with(base, verdict: .incompatible,
                            reason: .localized("The signing authorization has expired. Renew it before downloading an update."))
            }
        }
        if let size = candidate.release.size, size > 0, let available = context.availableBytes, size > available {
            return with(base, verdict: .incompatible,
                        reason: .localized("The device does not report enough free space for this update."))
        }
        if let digest = candidate.release.sha256, !Self.isDigest(digest) {
            return with(base, verdict: .incompatible,
                        reason: .localized("The catalog integrity value is not a SHA-256 digest. No download was started."))
        }
        let request: CatalogDownloadRequest
        do {
            request = try CatalogDownloadResolver.resolve(
                app: candidate.app, release: candidate.release,
                integrityVerified: context.catalogIntegrityVerified
            )
        } catch {
            return with(base, verdict: .incompatible, reason: error.localizedDescription)
        }
        return DeviceUpdatePlan(
            bundleIdentifier: base.bundleIdentifier, installedName: base.installedName,
            installedVersion: base.installedVersion, candidateVersion: base.candidateVersion,
            sourceName: base.sourceName, verdict: .updateAvailable,
            reason: .localized("Use the existing download, verification and signing pipeline to prepare this release."),
            download: request
        )
    }

    private static func with(_ plan: DeviceUpdatePlan, verdict: DeviceUpdateVerdict,
                             reason: String) -> DeviceUpdatePlan {
        DeviceUpdatePlan(bundleIdentifier: plan.bundleIdentifier, installedName: plan.installedName,
                         installedVersion: plan.installedVersion, candidateVersion: plan.candidateVersion,
                         sourceName: plan.sourceName, verdict: verdict, reason: reason, download: nil)
    }

    private static func isDigest(_ raw: String) -> Bool {
        raw.utf8.count == 64 && raw.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// Starts a catalog download through VexSign's existing download manager. The manager owns
/// transfer, checksum verification, import and the signing hand-off; this port only forwards
/// the resolved request.
protocol DeviceUpdateDownloading: Sendable {
    @discardableResult
    func start(_ request: CatalogDownloadRequest) -> Bool
}

struct PairedDeviceUpdateDownloader: DeviceUpdateDownloading {
    func start(_ request: CatalogDownloadRequest) -> Bool {
        let expectation = DownloadIntegrity.Expectation(
            byteCount: request.expectation.byteCount, sha256: request.expectation.sha256
        )
        let download = DownloadManager.shared.startDownload(
            from: request.url, id: request.bundleIdentifier + "|" + request.version,
            appName: request.appName, appDescription: request.appDescription,
            originURL: nil,
            integrity: expectation.isEmpty ? nil : expectation
        )
        // The manager returns an untracked placeholder when Game Mode, Wi-Fi-only,
        // charge-only, URL policy or a missing session refuses the request. URL equality
        // is true for that placeholder too, so identity is the only valid verdict.
        return DownloadManager.shared.isTracked(download)
    }
}

/// Best-effort volume capacity for the app's own container. Returns nil when the platform
/// does not expose a number; update planning then refuses to claim insufficient storage.
enum DeviceStorageAvailability {
    static func importantUsageBytes() -> Int64? {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        do {
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let bytes = values.volumeAvailableCapacityForImportantUsage, bytes >= 0 else { return nil }
            return bytes
        } catch {
            return nil
        }
    }
}
