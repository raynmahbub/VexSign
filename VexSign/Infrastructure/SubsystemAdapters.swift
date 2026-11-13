import Foundation
import CoreData
import Nuke
import AltSourceKit
import NimbleExtensions

// MARK: - Workspace Reset Adapter

@MainActor
final class CoreDataWorkspaceResetAdapter: WorkspaceResetting {
    func currentSummary() -> WorkspaceCountsSummary {
        var totalCacheSize = URLCache.shared.currentDiskUsage
        if let nukeCache = ImagePipeline.shared.configuration.dataCache as? DataCache {
            totalCacheSize += nukeCache.totalSize
        }

        return WorkspaceCountsSummary(
            networkCacheSizeFormatted: Int64(totalCacheSize).formattedFileSize,
            sourcesCountText: Storage.shared.countSources(),
            signedAppsCountText: Storage.shared.countSignedApps(),
            importedAppsCountText: Storage.shared.countImportedApps(),
            tweaksCount: TweakManager.shared.tweaks.count,
            certificatesCountText: Storage.shared.countCertificates()
        )
    }

    func perform(_ scope: WorkspaceResetScope) {
        switch scope {
        case .workCache:
            StorageManager.purgeTemporary()
        case .networkCache:
            clearNetworkCache()
        case .sources:
            Storage.shared.clearSources()
        case .signedApps:
            Storage.shared.clearSignedApps()
        case .importedApps:
            Storage.shared.clearImportedApps()
        case .tweaks:
            TweakManager.shared.resetLibrary()
        case .certificates(let resetAll):
            Storage.shared.clearCertificates(resetSelection: !resetAll)
        case .userDefaults:
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
        case .all:
            StorageManager.purgeTemporary()
            clearNetworkCache()
            Storage.shared.clearSources()
            Storage.shared.clearSignedApps()
            Storage.shared.clearImportedApps()
            TweakManager.shared.resetLibrary()
            Storage.shared.clearCertificates(resetSelection: false)
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
        }
        SubsystemDiagnosticsLog.info("Completed workspace reset scope: \(String(describing: scope))", subsystem: .storage)
    }

    private func clearNetworkCache() {
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)

        if let dataCache = ImagePipeline.shared.configuration.dataCache as? DataCache {
            dataCache.removeAll()
        }
        if let imageCache = ImagePipeline.shared.configuration.imageCache as? Nuke.ImageCache {
            imageCache.removeAll()
        }
    }
}

// MARK: - Staged Downloaded Files Adapter

@MainActor
final class FileSystemDownloadedFilesAdapter: DownloadedFilesManaging {
    private static let supportedExtensions: Set<String> = ["ipa", "zip", "deb"]

    func listStagedPackages() -> [DownloadedFileItem] {
        let staging = FileManager.default.downloadStaging
        do {
            try FileManager.default.createDirectoryIfNeeded(at: staging)
            let urls = try FileManager.default.contentsOfDirectory(
                at: staging,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            let items: [DownloadedFileItem] = urls.compactMap { url in
                guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    return DownloadedFileItem(
                        name: url.lastPathComponent,
                        url: url,
                        size: Int64(values.fileSize ?? 0),
                        date: values.contentModificationDate ?? Date()
                    )
                } catch {
                    SubsystemDiagnosticsLog.warn(
                        "Failed reading resource attributes for \(url.lastPathComponent): \(error.localizedDescription)",
                        subsystem: .storage
                    )
                    return DownloadedFileItem(
                        name: url.lastPathComponent,
                        url: url,
                        size: 0,
                        date: Date()
                    )
                }
            }
            return items.sorted { $0.date > $1.date }
        } catch {
            SubsystemDiagnosticsLog.warn(
                "Could not list download staging directory: \(error.localizedDescription)",
                subsystem: .storage
            )
            return []
        }
    }

    func importFiles(_ urls: [URL], intoStaging: Bool) -> Int {
        let directory = intoStaging ? FileManager.default.downloadStaging : FileManager.default.unsigned
        return FileManagerActions.importFiles(urls, into: directory)
    }

    func importToLibrary(from stagedURL: URL) -> Bool {
        FileManagerActions.importFiles([stagedURL], into: FileManager.default.unsigned) > 0
    }

    func stagingDirectoryURL() -> URL {
        FileManager.default.downloadStaging
    }

    func sharedDocumentsURL(for url: URL) -> URL? {
        url.toSharedDocumentsURL()
    }
}

// MARK: - Diagnostics Adapter

@MainActor
final class DiagnosticsRepositoryAdapter: DiagnosticsProviding {
    func currentSnapshot() -> DiagnosticOverviewSnapshot {
        let certificates = Storage.shared.getAllCertificates()
        let sources = Storage.shared.getSources()
        let staleIDs = SourcesViewModel.shared.staleSourceIDs

        let certItems: [CertificateSummaryItem] = certificates.map { cert in
            let days = cert.expiration.map { Int($0.timeIntervalSinceNow / 86_400) }
            return CertificateSummaryItem(
                id: cert.uuid ?? cert.objectID.uriRepresentation().absoluteString,
                displayName: cert.nickname ?? cert.uuid ?? .localized("Certificate"),
                expiration: cert.expiration,
                daysRemaining: days,
                isExpiringSoon: (days ?? 999) < 14,
                isRevoked: cert.revoked
            )
        }

        let failingSourceNames: [String] = sources.compactMap { source in
            let id = source.identifier ?? source.sourceURL?.absoluteString ?? ""
            guard SourcePreferences.lastError(for: id) != nil else { return nil }
            return source.name ?? id
        }

        let recentTasks = UnifiedTaskCenter.shared.history.prefix(5).map { task in
            DiagnosticTaskSummary(
                id: task.id,
                title: task.title,
                iconName: task.kind.icon,
                phaseTitle: task.phase.title,
                isFailed: task.phase == .failed
            )
        }

        return DiagnosticOverviewSnapshot(
            migrationWarnings: CredentialMigrationDiagnostics.shared.warnings.map(\.message),
            certificateCount: certItems.count,
            expiringCertificateCount: certItems.filter(\.isExpiringSoon).count,
            repositoryCount: sources.count,
            failingRepositoryCount: failingSourceNames.count,
            staleSourceCount: staleIDs.count,
            certificates: certItems,
            failingSourceNames: failingSourceNames,
            recentTasks: recentTasks
        )
    }

    func exportDiagnosticArchiveURL() -> URL? {
        DiagnosticBundleExporter.createDiagnosticBundle()
    }
}

// MARK: - App Privacy Adapter

@MainActor
final class AppPrivacyAdapter: AppPrivacyManaging {
    var strictHidingEnabled: Bool {
        get { AppLockManager.shared.strictHidingEnabled }
        set { AppLockManager.shared.strictHidingEnabled = newValue }
    }

    var isRevealingHiddenApps: Bool {
        AppLockManager.shared.isRevealingHiddenApps
    }

    var biometryDisplayName: String? {
        AppLockManager.biometryName
    }

    func allLibraryApps() -> [AppPrivacyItem] {
        Storage.shared.getAllApps().compactMap { app in
            guard let uuid = app.uuid else { return nil }
            return AppPrivacyItem(
                id: "\(app.isSigned ? "signed" : "imported"):\(uuid)",
                uuid: uuid,
                name: app.name ?? .localized("Unknown"),
                identifier: app.identifier ?? "",
                version: app.version ?? "1.0",
                isSigned: app.isSigned,
                isLocked: AppLockManager.shared.isAppLocked(uuid),
                isHidden: AppLockManager.shared.isAppHidden(uuid),
                bundleURL: Storage.shared.getAppDirectory(for: app)
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isAppLocked(_ uuid: String) -> Bool {
        AppLockManager.shared.isAppLocked(uuid)
    }

    func isAppHidden(_ uuid: String) -> Bool {
        AppLockManager.shared.isAppHidden(uuid)
    }

    func toggleAppLock(_ uuid: String) {
        AppLockManager.shared.toggleAppLock(uuid)
    }

    func toggleHideApp(_ uuid: String) {
        AppLockManager.shared.toggleHideApp(uuid)
    }

    func authenticateToRevealHidden(completion: @escaping (Bool) -> Void) {
        AppLockManager.shared.authenticateToRevealHidden(completion: completion)
    }
}

// MARK: - Certificate Catalog Adapter

@MainActor
final class CertificateCatalogAdapter: CertificateCatalogProviding {
    func certificateOptions() -> [CertificateOptionItem] {
        Storage.shared.getAllCertificates().compactMap { cert in
            let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
            let resolved = cert.nickname ?? decoded?.Name ?? "Certificate"
            let display = resolved == "Certificate" ? .localized("Certificate") : resolved
            let id = cert.uuid ?? cert.objectID.uriRepresentation().absoluteString
            return CertificateOptionItem(id: id, tagName: resolved, displayName: display)
        }
    }

    func signedAppsCount() -> Int {
        Storage.shared.getAllApps().filter(\.isSigned).count
    }
}
