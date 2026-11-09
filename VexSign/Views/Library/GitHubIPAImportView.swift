import SwiftUI
import NimbleExtensions

/// Explicit release tracking and manual asset selection; polling never imports or signs.
struct GitHubIPAImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var trackingBundleID = ""
    @ObservedObject private var tracking = GitHubSubscriptionStore.shared
    @State private var includePrereleases = false
    @State private var releases: [GitHubIPAReleases.Release] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var requestTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(.localized("owner/repository or GitHub URL"), text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(isLoading)
                    Toggle(.localized("Include Prereleases"), isOn: $includePrereleases)
                        .disabled(isLoading)
                    Button(.localized("Find IPA Releases")) { load() }
                        .disabled(isLoading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text(.localized("Queries GitHub's public API without signing in. Shows up to 20 recent releases. Choosing an IPA uses your existing download and auto-sign settings."))
                }
                Section {
                    TextField(.localized("Bundle identifier for release tracking"), text: $trackingBundleID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let warning = tracking.warning { Text(warning).foregroundStyle(.orange) }
                    ForEach(tracking.subscriptions) { subscription in
                        VStack(alignment: .leading) {
                            Text(verbatim: subscription.repository + " · " + subscription.bundleID)
                            Text(verbatim: subscription.tag + " · " + subscription.assetName).font(.caption)
                            Text(subscription.nextCheck, style: .relative).font(.caption)
                            Button(.localized("Check tracked releases")) { check(subscription) }
                                .disabled(isLoading || Date() < subscription.nextCheck)
                            Button(.localized("Review cached releases")) { reviewCached(subscription) }
                                .disabled(isLoading || subscription.cachedMetadata == nil)
                            Toggle(.localized("Check during enabled maintenance"), isOn: Binding(
                                get: { subscription.maintenanceChecks == true },
                                set: { tracking.setMaintenanceChecks(subscription.id, enabled: $0) }))
                            Button(.localized("Stop tracking"), role: .destructive) { tracking.remove(subscription.id) }
                        }
                    }
                } header: { Text(.localized("Tracked GitHub releases")) } footer: {
                    Text(.localized("Tracking stores the explicitly chosen release and asset IDs with a bundle identifier for per-app update rules. Checks are rate-limited and reuse conditional metadata. Optional maintenance checks require automation to be enabled and never download or choose replacement assets automatically. At most 10 subscriptions are retained. Review every new release; asset names alone do not establish app identity."))
                }
                if isLoading { ProgressView() }
                if let errorMessage {
                    Section {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                ForEach(releases) { release in
                    Section {
                        if release.prerelease {
                            Label(.localized("Prerelease"), systemImage: "testtube.2")
                                .foregroundStyle(.orange)
                        }
                        ForEach(release.assets) { asset in
                            Button {
                                TabSelectionObserver.shared.librarySection = .apps
                                _ = DownloadManager.shared.startDownload(
                                    from: asset.browser_download_url,
                                    id: "VexSignManualDownload_\(UUID().uuidString)",
                                    appName: asset.name,
                                    integrity: asset.integrity
                                )
                                dismiss()
                            } label: {
                                Label(asset.name, systemImage: "arrow.down.circle")
                                    .multilineTextAlignment(.leading)
                            }
                            Button(.localized("Track this release and asset")) {
                                do {
                                    let repository = try GitHubIPAReleases.Repository(input)
                                    tracking.track(repository: repository, release: release, asset: asset,
                                                   bundleID: trackingBundleID, includePrereleases: includePrereleases)
                                } catch { errorMessage = error.localizedDescription }
                            }.disabled(trackingBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } header: {
                        Text(verbatim: release.name.flatMap { $0.isEmpty ? nil : $0 } ?? release.tag_name)
                    }
                }
                Section {
                    Text(.localized("Public availability is not a safety guarantee. Only import IPAs from developers you trust. Tracked releases require explicit review; nothing is downloaded automatically."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(.localized("Import from GitHub"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Close")) { dismiss() }
                }
            }
            .onChange(of: input) { _, _ in clearResults() }
            .onChange(of: includePrereleases) { _, _ in clearResults() }
            .onDisappear { requestTask?.cancel() }
        }
    }

    @MainActor
    private func reviewCached(_ subscription: GitHubSubscriptionStore.Subscription) {
        guard !isLoading else { return }
        // Cached metadata is untrusted and revalidated on every review.
        input = subscription.repository
        includePrereleases = subscription.includePrereleases
        trackingBundleID = subscription.bundleID
        requestTask = Task { @MainActor in
            // Let input-change invalidation finish before publishing the cache snapshot.
            await Task.yield()
            guard !Task.isCancelled else { return }
            do {
                releases = try tracking.cachedReleases(subscription.id)
                errorMessage = releases.isEmpty ? .localized("No reviewable releases, or this app's update rules currently suppress tracking.") : nil
            } catch { errorMessage = error.localizedDescription }
            requestTask = nil
        }
    }

    @MainActor
    private func check(_ subscription: GitHubSubscriptionStore.Subscription) {
        guard !isLoading, !GameMode.isEnabled else { return }
        releases = []
        errorMessage = nil
        isLoading = true
        // Assign before launching; input-change cleanup cannot erase the returned results.
        input = subscription.repository
        includePrereleases = subscription.includePrereleases
        trackingBundleID = subscription.bundleID
        requestTask = Task { @MainActor in
            defer { isLoading = false; requestTask = nil }
            do {
                let found = try await tracking.check(subscription.id)
                try Task.checkCancellation()
                releases = found
                if found.isEmpty { errorMessage = .localized("No reviewable releases, or this app's update rules currently suppress tracking.") }
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }

    private func clearResults() {
        releases = []
        errorMessage = nil
    }

    @MainActor
    private func load() {
        guard !isLoading else { return }
        guard !GameMode.isEnabled else {
            GameMode.reportBlocked(.localized("Downloading"))
            return
        }
        clearResults()
        isLoading = true
        let repositoryInput = input
        let wantsPrereleases = includePrereleases
        requestTask = Task { @MainActor in
            defer { isLoading = false; requestTask = nil }
            do {
                let repository = try GitHubIPAReleases.Repository(repositoryInput)
                let found = try await GitHubIPAReleases.fetch(repository, includePrereleases: wantsPrereleases)
                try Task.checkCancellation()
                releases = found
                if found.isEmpty { errorMessage = GitHubIPAReleases.Failure.noAssets.localizedDescription }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}
