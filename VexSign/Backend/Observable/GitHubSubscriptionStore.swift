import Foundation
import Combine
import NimbleExtensions

/// One main-actor owner prevents concurrent windows from overwriting release tracking state.
/// Tracking is review-only: no guessed asset replacement, download, or signing from a poll.
@MainActor
final class GitHubSubscriptionStore: ObservableObject {
    static let shared = GitHubSubscriptionStore()
    enum Failure: LocalizedError {
        case persistence
        var errorDescription: String? { .localized("Release tracking state could not be saved. No request or update was accepted; retry after storage access is restored.") }
    }
    typealias Fetcher = (GitHubIPAReleases.Repository, String?) async throws -> GitHubIPAReleases.MetadataResponse
    struct Subscription: Codable, Identifiable {
        let id: UUID
        let repository: String
        let bundleID: String
        let includePrereleases: Bool
        let releaseID: Int64
        let assetID: Int64
        let assetName: String
        let tag: String
        var etag: String?
        var cachedMetadata: Data?
        var nextCheck: Date
        var maintenanceChecks: Bool? = nil
    }
    @Published private(set) var subscriptions: [Subscription] = []
    @Published var warning: String?
    private var inFlight = Set<String>()
    private let fetcher: Fetcher
    private let now: () -> Date
    private let ruleForBundle: (String) -> PerAppUpdateRule
    private let file: URL
    private var writable = true

    init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitHubSubscriptions.json"),
         fetcher: @escaping Fetcher = { repository, etag in try await GitHubIPAReleases.fetchMetadata(repository, etag: etag) },
         now: @escaping () -> Date = { Date() },
         ruleForBundle: @escaping (String) -> PerAppUpdateRule = { PerAppUpdateRulesStore.persisted[$0] ?? PerAppUpdateRule() }) {
        self.file = file
        self.fetcher = fetcher
        self.now = now
        self.ruleForBundle = ruleForBundle
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let records = try JSONDecoder().decode([Subscription].self, from: Data(contentsOf: file))
            guard records.count <= 10, Set(records.map(\.id)).count == records.count else { throw CocoaError(.fileReadCorruptFile) }
            for record in records {
                _ = try GitHubIPAReleases.Repository(record.repository)
                guard !record.bundleID.isEmpty, record.bundleID.count <= 255,
                      record.releaseID > 0, record.assetID > 0,
                      (record.cachedMetadata?.count ?? 0) <= GitHubIPAReleases.metadataLimit else { throw CocoaError(.fileReadCorruptFile) }
            }
            subscriptions = records
        } catch {
            writable = false // Preserve inaccessible/corrupt state; never overwrite it with an empty array.
            warning = error.localizedDescription
        }
    }

    func track(repository: GitHubIPAReleases.Repository, release: GitHubIPAReleases.Release,
               asset: GitHubIPAReleases.Asset, bundleID: String, includePrereleases: Bool) {
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard writable, !bundleID.isEmpty, bundleID.count <= 255, asset.isAllowed(for: repository) else { return }
        let previous = subscriptions.filter { $0.repository.lowercased() == repository.slug.lowercased() }.max { $0.nextCheck < $1.nextCheck }
        var next = subscriptions.filter { !($0.repository.lowercased() == repository.slug.lowercased() && $0.bundleID == bundleID) }
        guard next.count < 10 else { return }
        next.append(Subscription(id: UUID(), repository: repository.slug, bundleID: bundleID,
                                 includePrereleases: includePrereleases, releaseID: release.id, assetID: asset.id,
                                 assetName: asset.name, tag: release.tag_name, etag: previous?.etag, cachedMetadata: previous?.cachedMetadata, nextCheck: previous?.nextCheck ?? .distantPast,
                                 maintenanceChecks: subscriptions.first(where: { $0.repository.lowercased() == repository.slug.lowercased() && $0.bundleID == bundleID })?.maintenanceChecks))
        commit(next)
    }

    func remove(_ id: UUID) { commit(subscriptions.filter { $0.id != id }) }

    func setMaintenanceChecks(_ id: UUID, enabled: Bool) {
        var next = subscriptions
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].maintenanceChecks = enabled
        commit(next)
    }

    /// Cache review never bypasses cooldown or makes a network request.
    func cachedReleases(_ id: UUID) throws -> [GitHubIPAReleases.Release] {
        guard let record = subscriptions.first(where: { $0.id == id }), let data = record.cachedMetadata else { return [] }
        let repository = try GitHubIPAReleases.Repository(record.repository)
        return reviewable(try GitHubIPAReleases.decode(data, repository: repository, includePrereleases: record.includePrereleases), for: record)
    }

    private func reviewable(_ releases: [GitHubIPAReleases.Release], for record: Subscription) -> [GitHubIPAReleases.Release] {
        let rule = ruleForBundle(record.bundleID)
        let sourceID = "github:" + record.repository.lowercased()
        guard !rule.disableUpdates, rule.ignoredSourceID != sourceID,
              rule.preferredSourceID == nil || rule.preferredSourceID == sourceID else { return [] }
        // GitHub returns recent releases first. Do not surface older cached releases as updates.
        return releases.prefix(while: { $0.id != record.releaseID }).filter {
            rule.ignoredVersion == nil || rule.ignoredVersion?.caseInsensitiveCompare($0.tag_name) != .orderedSame
        }
    }

    struct MaintenanceResult { var checked = 0; var reviewable = 0; var failed = 0 }

    /// Opt-in metadata-only checks. The caller owns background runtime and automation consent.
    func checkDueSubscriptions() async -> MaintenanceResult {
        var result = MaintenanceResult()
        let due = subscriptions.filter { $0.maintenanceChecks == true && now() >= $0.nextCheck }
        for record in due {
            guard !Task.isCancelled, !GameMode.isEnabled else { break }
            guard let current = subscriptions.first(where: { $0.id == record.id }), now() >= current.nextCheck else { continue }
            do {
                _ = try await check(record.id)
                if subscriptions.first(where: { $0.id == record.id })?.nextCheck != current.nextCheck { result.checked += 1 }
            } catch {
                if error is CancellationError || Task.isCancelled { break }
                result.failed += 1
            }
        }
        for record in subscriptions where record.maintenanceChecks == true {
            do { result.reviewable += try cachedReleases(record.id).count }
            catch { result.failed += 1 }
        }
        return result
    }

    @discardableResult
    private func commit(_ records: [Subscription]) -> Bool {
        guard writable else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            subscriptions = records
            warning = nil
            return true
        } catch { warning = error.localizedDescription; return false }
    }

    func check(_ id: UUID) async throws -> [GitHubIPAReleases.Release] {
        guard writable, !GameMode.isEnabled,
              let record = subscriptions.first(where: { $0.id == id }) else { return [] }
        let repositoryKey = record.repository.lowercased()
        guard !inFlight.contains(repositoryKey), now() >= record.nextCheck else { return [] }
        let sourceID = "github:" + record.repository.lowercased()
        let rule = ruleForBundle(record.bundleID)
        guard !rule.disableUpdates, rule.ignoredSourceID != sourceID,
              rule.preferredSourceID == nil || rule.preferredSourceID == sourceID else { return [] }
        let repository = try GitHubIPAReleases.Repository(record.repository)
        inFlight.insert(repositoryKey)
        defer { inFlight.remove(repositoryKey) }
        // Persist a cooldown before awaiting networking; relaunch cannot erase a failed-request loop.
        var pending = subscriptions
        for index in pending.indices where pending[index].repository.lowercased() == repositoryKey {
            pending[index].nextCheck = now().addingTimeInterval(300)
        }
        guard commit(pending) else { throw Failure.persistence }
        let response = try await fetcher(repository, record.etag)
        try Task.checkCancellation()
        guard subscriptions.contains(where: { $0.id == id }) else { return [] }
        var next = subscriptions
        for offset in next.indices where next[offset].repository.lowercased() == repositoryKey {
            next[offset].nextCheck = response.retryAt
        }
        guard response.status == 200 || response.status == 304 else {
            guard commit(next) else { throw Failure.persistence }
            throw GitHubIPAReleases.Failure.requestFailed(response.status)
        }
        guard let data = response.data ?? record.cachedMetadata else { throw GitHubIPAReleases.Failure.invalidResponse }
        let releases = try GitHubIPAReleases.decode(data, repository: repository, includePrereleases: record.includePrereleases)
        for offset in next.indices where next[offset].repository.lowercased() == repositoryKey {
            next[offset].cachedMetadata = data
            next[offset].etag = response.etag ?? record.etag
        }
        guard commit(next) else { throw Failure.persistence }
        // Preferences can change while networking suspends this actor. Recheck before publication.
        guard !GameMode.isEnabled else { return [] }
        return reviewable(releases, for: record)
    }
}
