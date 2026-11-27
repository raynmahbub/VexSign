// MARK: - Application sources and catalog workspace state
//
// Presentation never parses JSON, reads files or signs anything itself. It
// asks the catalog services for validated snapshots and hands download requests
// to the existing download manager, which owns import, verification and the
// signing hand-off.

import Foundation
import UIKit
import Combine
import NimbleExtensions

@MainActor
final class CatalogWorkspaceModel: ObservableObject {
    @Published private(set) var sources: [CatalogSourceRecord] = []
    @Published private(set) var snapshots: [String: CatalogSnapshot] = [:]
    @Published private(set) var hits: [CatalogSearchHit] = []
    @Published private(set) var updates: [CatalogUpdateCandidate] = []
    @Published private(set) var isBusy = false
    @Published var query = CatalogSearchQuery()
    @Published var message: String?

    private let container: AppContainer
    private let registry: CatalogSourceRegistry
    private let persistence: CatalogPersistence
    private let refresh: CatalogRefreshService
    private let pageSize = 250

    init(
        container: AppContainer,
        registry: CatalogSourceRegistry? = nil,
        persistence: CatalogPersistence = CatalogPersistence(),
        refresh: CatalogRefreshService? = nil
    ) {
        self.container = container
        self.persistence = persistence
        let registry = registry ?? CatalogSourceRegistry(persistence: persistence)
        self.registry = registry
        self.refresh = refresh ?? CatalogRefreshService(fetcher: CatalogRefreshService.liveFetcher(),
                                                        registry: registry, persistence: persistence)
    }

    func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let configured = container.workspace.snapshot.repositories
            let reconciled = try await registry.reconcile(configured: configured)
            sources = reconciled
            // Disabled sources remain browsable from their last validated cache;
            // they are simply not contacted for a refresh.
            snapshots = try await persistence.allSnapshots(sourceIDs: reconciled.map(\.id))
            applySearch()
            applyUpdates()
        } catch { message = error.localizedDescription }
    }

    func addSource(address: String, format: CatalogSourceFormat) async {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            // Content is validated before any source is persisted.
            let preview = try await refresh.preview(address: address, format: format)
            let url = try SourceURLPolicy.normalizeAndValidate(address)
            let added: Result<String, Error> = await withCheckedContinuation { continuation in
                container.repositories.add(address: url.absoluteString) { continuation.resume(returning: $0) }
            }
            switch added {
            case .failure(let error):
                message = error.localizedDescription
                isBusy = false
                return
            case .success: break
            }
            let source: CatalogSourceRecord
            do {
                source = try await registry.add(
                    url: url, name: preview.name ?? url.host ?? address,
                    format: format, declaredIdentifier: preview.sourceID
                )
            } catch CatalogSourceError.duplicateSource {
                message = .localized("This repository is already configured.")
                await load()
                return
            }
            _ = try await registry.recordRefresh(
                id: source.id,
                outcome: .verified(preview, integrityVerified: false),
                duration: 0,
                statusCode: nil
            )
            message = String.localized("Added %@ with %lld validated applications.", arguments: preview.name ?? address, preview.apps.count)
            await load()
        } catch { message = error.localizedDescription }
    }

    func removeSource(_ source: CatalogSourceRecord) {
        guard let record = container.workspace.snapshot.repositories.first(where: {
            CatalogSourceRegistry.id(for: $0) == source.id
        }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try container.repositories.remove([record], offeringUndo: false)
                try await registry.remove(id: source.id)
                await load()
            } catch { message = error.localizedDescription }
        }
    }

    func updateMetadata(
        _ source: CatalogSourceRecord,
        name: String,
        summary: String?,
        artworkURL: String?,
        format: CatalogSourceFormat
    ) async {
        do {
            _ = try await registry.update(
                id: source.id, name: name, summary: summary,
                artworkURL: artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines), format: format
            )
            message = .localized("Source metadata saved.")
            await load()
        } catch { message = error.localizedDescription }
    }

    func setEnabled(_ source: CatalogSourceRecord, enabled: Bool) {
        SourcePreferences.setEnabled(enabled, for: source.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await registry.setEnabled(id: source.id, enabled: enabled)
                await load()
            } catch { message = error.localizedDescription }
        }
    }

    func refreshAll() async {
        isBusy = true
        defer { isBusy = false }
        let configured = container.workspace.snapshot.repositories
        await container.sources.fetchSources(configured, refresh: true)
        _ = await refresh.refreshAll()
        await load()
    }

    func refresh(_ source: CatalogSourceRecord) async {
        isBusy = true
        defer { isBusy = false }
        let configured = container.workspace.snapshot.repositories.filter {
            CatalogSourceRegistry.id(for: $0) == source.id
        }
        await container.sources.fetchSources(configured, refresh: true, configuredSources: configured)
        do {
            _ = try await refresh.refresh(sourceID: source.id)
            await load()
        } catch { message = error.localizedDescription }
    }

    func search() {
        applySearch()
    }

    func download(_ app: CatalogAppRecord, release: CatalogRelease? = nil) {
        let source = sources.first { $0.id == app.sourceID }
        do {
            let request = try CatalogDownloadResolver.resolve(
                app: app, release: release, integrityVerified: source?.integrityVerified ?? false
            )
            let expectation = DownloadIntegrity.Expectation(
                byteCount: request.expectation.byteCount, sha256: request.expectation.sha256
            )
            let download = DownloadManager.shared.startDownload(
                from: request.url,
                id: app.id,
                appName: request.appName,
                appDescription: request.appDescription,
                originURL: URL(string: app.sourceURL),
                integrity: expectation.isEmpty ? nil : expectation
            )
            // A refused request returns an untracked placeholder with the same URL.
            // Never claim the transfer started until the manager registered it.
            if DownloadManager.shared.isTracked(download) {
                message = String.localized("Downloading %@ %@ from %@.", arguments: app.name, request.version, app.sourceName)
            } else {
                message = .localized("The download manager refused this release. Check the release URL and your download settings, then retry.")
            }
        } catch { message = error.localizedDescription }
    }

    func updateDownload(_ candidate: CatalogUpdateCandidate) {
        download(candidate.app, release: candidate.release)
    }

    private func applySearch() {
        hits = Array(CatalogSearch.search(snapshots: snapshots, query: query).prefix(pageSize))
    }

    private func applyUpdates() {
        let installed = container.workspace.snapshot.apps.map {
            CatalogInstalledApp(
                name: $0.name ?? "",
                bundleIdentifier: $0.identifier ?? $0.originalIdentifier ?? "",
                version: $0.version,
                sourceURL: $0.source?.absoluteString,
                recordID: $0.recordID
            )
        }
        let hasIdentity = SigningIdentityAvailability.hasUsableIdentity(
            in: container.workspace.snapshot.certificates
        )
        updates = CatalogUpdateDetector.detect(
            installed: installed,
            apps: snapshots.values.flatMap(\.apps),
            currentOSVersion: UIDevice.current.systemVersion,
            signingIdentityAvailable: hasIdentity
        )
    }
}
