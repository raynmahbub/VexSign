//
//  AppStoreView.swift
//  VexSign — Apple App Store redesign, merges Sources. Single nav bar.
//  Ported from App Store, SideStore, and Ksign with modern Apple feel.
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import NukeUI
import CoreData
import AltSourceKit

// MARK: - App Store (Apple Official Style) — Single NavigationStack, Sources merged

struct AppStoreView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var viewModel = SourcesViewModel.shared
    @ObservedObject private var updateChecker = AppUpdateChecker.shared
    @ObservedObject private var premiumFilter = PremiumFilterPreferences.shared
    @ObservedObject private var privacyManager = AppLockManager.shared

    @FetchRequest(entity: Signed.entity(), sortDescriptors: [])
    private var signedApps: FetchedResults<Signed>

    @FetchRequest(entity: Imported.entity(), sortDescriptors: [])
    private var importedApps: FetchedResults<Imported>

    @State private var searchText = ""
    @State private var selectedSegment: StoreSegment = .discover
    @State private var isAddingPresenting = false
    @State private var appSortOption: AppSortOption = .name
    @State private var selectedCategory: String = "All"
    @State private var catalogItems: [SourcedAppItem] = []
    @State private var filteredCatalogItems: [SourcedAppItem] = []
    @State private var catalogRevision = 0
    @State private var catalogBuildGeneration = 0
    @State private var catalogFilterGeneration = 0
    @AppStorage("VexSign.repositorySort") private var _repositorySortRaw = RepositorySortOption.priority.rawValue

    private let appCategories = ["All", "Utilities", "Emulators", "Tweaked", "Games", "Jailbreak"]

    private let communityRepos: [CommunityRepoItem] = [
        .init(name: "SideStore Community", subtitle: "Official SideStore community apps", url: URL(string: "https://community-apps.sidestore.io/sidecommunity.json")!, iconName: "globe.desk.fill"),
        .init(name: "Ksign Repo", subtitle: "Esign-style curated tools & signers", url: URL(string: "https://raw.githubusercontent.com/Nyasami/Ksign/refs/heads/main/repo.json")!, iconName: "app.badge.fill"),
        .init(name: "LiveContainer", subtitle: "Run multiple iOS apps side-by-side", url: URL(string: "https://raw.githubusercontent.com/LiveContainer/LiveContainer/refs/heads/main/apps.json")!, iconName: "square.stack.3d.up.fill"),
        .init(name: "OatmealDome", subtitle: "Dolphin iOS & emulation utilities", url: URL(string: "https://altstore.oatmealdome.me/")!, iconName: "gamecontroller.fill"),
        .init(name: "Aidoku", subtitle: "Manga & comic reader", url: URL(string: "https://raw.githubusercontent.com/Aidoku/Aidoku/altstore/apps.json")!, iconName: "book.fill"),
        .init(name: "Flycast", subtitle: "Sega Dreamcast emulator", url: URL(string: "https://github.com/chachillie/Flycast-iOS/raw/main/flycast-ios.json")!, iconName: "play.circle.fill"),
        .init(name: "iTorrent", subtitle: "BitTorrent client for iOS", url: URL(string: "https://xitrix.github.io/iTorrent/AltStore.json")!, iconName: "arrow.down.circle.fill"),
        .init(name: "UTM", subtitle: "Virtual machines & Linux on iOS", url: URL(string: "https://alt.getutm.app")!, iconName: "display")
    ]

    struct CommunityRepoItem: Identifiable {
        var id: String { url.absoluteString }
        let name: String
        let subtitle: String
        let url: URL
        let iconName: String
    }

    @FetchRequest(
        entity: AltSource.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
        animation: .snappy
    ) private var sources: FetchedResults<AltSource>

    enum StoreSegment: String, CaseIterable, Identifiable {
        case discover = "Discover"
        case apps = "Apps"
        case repositories = "Repositories"
        case updates = "Updates"
        var id: String { rawValue }
    }

    enum AppSortOption: String, CaseIterable {
        case name = "Name"
        case date = "Date"
        case size = "Size"
    }

    enum RepositorySortOption: String, CaseIterable {
        case priority = "Priority"
        case name = "Name"
        case updated = "Last Updated"

        var label: String { .localized(rawValue) }
    }

    // Model representing an app combined with its source repository
    struct SourcedAppItem: Identifiable {
        var id: String { "\(sourceID)-\(app.id ?? app.currentName)" }
        let source: AltSource
        let sourceID: String
        let sourceName: String
        let repository: ASRepository
        let app: ASRepository.App
    }

    private struct CatalogSourceReference {
        let source: AltSource
        let sourceID: String
        let sourceName: String
        let repository: ASRepository
    }

    private struct CatalogInput {
        let sourceID: String
        let repository: ASRepository
    }

    private struct IndexedCatalogApp {
        let sourceIndex: Int
        let app: ASRepository.App
    }

    private var nonExcludedSources: [AltSource] {
        let visible = sources.filter { !VexSignAPI.isSourceExcluded($0.identifier ?? $0.sourceURL?.absoluteString ?? "") }
        let ids = visible.map { $0.identifier ?? $0.sourceURL?.absoluteString ?? "" }
        let order = SourcePreferences.order(for: ids).enumerated().reduce(into: [String: Int]()) { result, item in
            result[item.element] = item.offset
        }
        return visible.sorted {
            let lhs = order[$0.identifier ?? $0.sourceURL?.absoluteString ?? ""] ?? Int.max
            let rhs = order[$1.identifier ?? $1.sourceURL?.absoluteString ?? ""] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
        }
    }

    private var filteredSources: [AltSource] {
        let base = nonExcludedSources
        let matched = searchText.isEmpty ? base : base.filter { ($0.name ?? "").localizedCaseInsensitiveContains(searchText) }
        let selected = RepositorySortOption(rawValue: _repositorySortRaw) ?? .priority
        switch selected {
        case .priority:
            return matched
        case .name:
            return matched.sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
        case .updated:
            return matched.sorted {
                let lhs = SourcePreferences.lastFetch(for: $0.identifier ?? $0.sourceURL?.absoluteString ?? "") ?? .distantPast
                let rhs = SourcePreferences.lastFetch(for: $1.identifier ?? $1.sourceURL?.absoluteString ?? "") ?? .distantPast
                if lhs != rhs { return lhs > rhs }
                return ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
            }
        }
    }

    private var strictlyHiddenAppKeys: Set<String> {
        guard privacyManager.strictHidingEnabled, !privacyManager.isRevealingHiddenApps else { return [] }
        var keys = privacyManager.hiddenAppUUIDs
        for app in signedApps where app.uuid.map({ privacyManager.isStrictlyHidden($0) }) == true {
            if let identifier = app.identifier { keys.insert(identifier) }
            if let originalIdentifier = app.originalIdentifier { keys.insert(originalIdentifier) }
            if let name = app.name { keys.insert(name.lowercased()) }
        }
        for app in importedApps where app.uuid.map({ privacyManager.isStrictlyHidden($0) }) == true {
            if let identifier = app.identifier { keys.insert(identifier) }
            if let originalIdentifier = app.originalIdentifier { keys.insert(originalIdentifier) }
            if let name = app.name { keys.insert(name.lowercased()) }
        }
        return keys
    }

    // The catalog is flattened once after repository loading, off the main thread. App Store
    // sections read these cached arrays; no body evaluation walks every repository/app again.
    private var allSourcedApps: [SourcedAppItem] { catalogItems }
    private var sortedAndFilteredApps: [SourcedAppItem] { filteredCatalogItems }

    @MainActor
    private func rebuildAppCatalog() async {
        catalogBuildGeneration &+= 1
        let generation = catalogBuildGeneration
        let references: [CatalogSourceReference] = nonExcludedSources.compactMap { source in
            guard let repository = viewModel.sources[source] else { return nil }
            let sourceID = source.identifier ?? source.sourceURL?.absoluteString ?? source.objectID.uriRepresentation().absoluteString
            return CatalogSourceReference(
                source: source,
                sourceID: sourceID,
                sourceName: source.name ?? "",
                repository: repository
            )
        }
        let inputs = references.map { CatalogInput(sourceID: $0.sourceID, repository: $0.repository) }
        let hiddenKeys = strictlyHiddenAppKeys
        let hideDuplicates = SourcePreferences.hideDuplicates

        let worker = Task.detached(priority: .userInitiated) {
            var result: [IndexedCatalogApp] = []
            var seenIDs = Set<String>()

            for (sourceIndex, input) in inputs.enumerated() {
                guard !Task.isCancelled else { return [IndexedCatalogApp]() }
                for app in input.repository.apps {
                    guard !Task.isCancelled else { return [IndexedCatalogApp]() }
                    let appID = app.id ?? app.currentName
                    guard !hiddenKeys.contains(appID), !hiddenKeys.contains(app.currentName.lowercased()) else { continue }
                    let uniqueKey = hideDuplicates ? appID : "\(input.sourceID)-\(appID)"
                    guard seenIDs.insert(uniqueKey).inserted else { continue }
                    result.append(IndexedCatalogApp(sourceIndex: sourceIndex, app: app))
                }
            }
            return result
        }
        let indexedItems = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        guard !Task.isCancelled, generation == catalogBuildGeneration else { return }
        catalogItems = indexedItems.map { indexed in
            let reference = references[indexed.sourceIndex]
            return SourcedAppItem(
                source: reference.source,
                sourceID: reference.sourceID,
                sourceName: reference.sourceName,
                repository: reference.repository,
                app: indexed.app
            )
        }
        catalogRevision &+= 1
    }

    @MainActor
    private func rebuildFilteredCatalog() async {
        catalogFilterGeneration &+= 1
        let generation = catalogFilterGeneration
        let items = catalogItems
        let category = selectedCategory.lowercased()
        let query = searchText
        let sortOption = appSortOption

        let worker = Task.detached(priority: .userInitiated) {
            let categoryFiltered = items.filter { item in
                guard category != "all" else { return true }
                let appCategory = (item.app.category ?? "").lowercased()
                let name = item.app.currentName.lowercased()
                let description = (item.app.currentDescription ?? "").lowercased()
                switch category {
                case "utilities":
                    return appCategory.contains("util") || appCategory.contains("tool") || name.contains("tool") || description.contains("util") || description.contains("manage")
                case "emulators":
                    return appCategory.contains("emu") || name.contains("emu") || description.contains("emulator") || description.contains("retro") || description.contains("gameboy") || description.contains("dolphin") || description.contains("utm")
                case "tweaked":
                    return name.contains("++") || name.contains("mod") || name.contains("pro") || name.contains("tweak") || description.contains("tweak") || description.contains("unlocked")
                case "games":
                    return appCategory.contains("game") || description.contains("game") || description.contains("play") || name.contains("game")
                case "jailbreak":
                    return appCategory.contains("jailbreak") || name.contains("troll") || description.contains("jailbreak") || description.contains("rootless") || description.contains("sileo")
                default:
                    return appCategory.contains(category) || name.contains(category)
                }
            }

            let searched = query.isEmpty ? categoryFiltered : categoryFiltered.filter {
                $0.app.currentName.localizedCaseInsensitiveContains(query) ||
                ($0.app.currentDescription ?? "").localizedCaseInsensitiveContains(query) ||
                $0.sourceName.localizedCaseInsensitiveContains(query)
            }

            guard !Task.isCancelled else { return [SourcedAppItem]() }
            switch sortOption {
            case .name:
                return searched.sorted { $0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending }
            case .date:
                return searched.sorted { ($0.app.date?.date ?? Date.distantPast) > ($1.app.date?.date ?? Date.distantPast) }
            case .size:
                return searched.sorted { ($0.app.size ?? 0) > ($1.app.size ?? 0) }
            }
        }
        let filtered = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        guard !Task.isCancelled, generation == catalogFilterGeneration else { return }
        filteredCatalogItems = filtered
    }

    private var updateCount: Int { updateChecker.updateCount }

    private struct SourceHealthSummary {
        let healthy: Int
        let failed: Int
        let stale: Int
        let neverFetched: Int
    }

    private var sourceHealth: SourceHealthSummary {
        let staleAfter: TimeInterval = 24 * 60 * 60
        var healthy = 0
        var failed = 0
        var stale = 0
        var neverFetched = 0

        for source in sources {
            let id = source.identifier ?? source.sourceURL?.absoluteString ?? ""
            if SourcePreferences.lastError(for: id) != nil {
                failed += 1
                continue
            }
            guard let fetched = SourcePreferences.lastFetch(for: id) else {
                neverFetched += 1
                continue
            }
            if Date().timeIntervalSince(fetched) > staleAfter {
                stale += 1
            } else {
                healthy += 1
            }
        }
        return SourceHealthSummary(healthy: healthy, failed: failed, stale: stale, neverFetched: neverFetched)
    }

    /// A lightweight, stable task identity. Passing `Array(FetchedResults)` to
    /// `.task(id:)` makes SwiftUI compare managed objects while Core Data is
    /// changing, which can restart the catalog load repeatedly on iOS 18/19.
    private var sourceRefreshKey: String {
        sources
            .compactMap { $0.sourceURL?.absoluteString }
            .sorted()
            .joined(separator: "\u{1F}")
    }

    private var catalogFilterKey: String {
        "\(catalogRevision)\u{1F}\(selectedCategory)\u{1F}\(appSortOption.rawValue)\u{1F}\(searchText)"
    }

    // MARK: - Body
    var body: some View {
        // ONE navigation bar — NBNavigationView is the only NavigationStack in this tab
        NBNavigationView(.localized("App Store"), displayMode: .large) {
            ScrollView {
                VStack(spacing: 20) {
                    // Apple official header styling
                    headerTodayDate

                    // Offline / stale-data notice: repositories that could not
                    // be refreshed keep their last saved catalog, clearly marked.
                    if !viewModel.staleSourceIDs.isEmpty {
                        offlineBanner
                    }

                    // Apple-style Segmented Pills
                    segmentPills

                    if !searchText.isEmpty {
                        // Live search across both Apps and Repositories
                        searchResultsView
                    } else {
                        // Section content based on selected segment
                        switch selectedSegment {
                        case .discover:
                            discoverSection
                        case .apps:
                            appsCatalogSection
                        case .repositories:
                            repositoriesSection
                        case .updates:
                            updatesSection
                        }
                    }

                    // Activity Logs reference (clean move to Settings, single nav bar)
                    logsMovedFooter
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .scrollIndicators(.hidden)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text(.localized("Search Apps & Sources")))
            .onReceive(TabSelectionObserver.shared.$searchRequest) { request in
                guard let request, request.tab == .appStore else { return }
                searchText = request.query
                TabSelectionObserver.shared.searchRequest = nil
            }
            .onReceive(TabSelectionObserver.shared.$appStoreSectionRequest) { request in
                guard let request, let segment = StoreSegment(rawValue: request) else { return }
                selectedSegment = segment
                searchText = ""
                TabSelectionObserver.shared.appStoreSectionRequest = nil
            }
            .refreshable {
                await viewModel.fetchSources(sources, refresh: true)
                await rebuildAppCatalog()
            }
            .toolbar { toolbarContent }
            .sheet(isPresented: $isAddingPresenting) {
                SourcesAddView().adaptiveSheetSizing()
            }
            .task(id: sourceRefreshKey) {
                await viewModel.fetchSources(sources)
                await rebuildAppCatalog()
            }
            .task(id: catalogFilterKey) {
                // Search input changes on every keystroke; discard the superseded query before
                // allocating a new off-main-thread filter/sort pass.
                do {
                    try await Task.sleep(nanoseconds: 120_000_000)
                } catch {
                    return // A newer search superseded this debounce.
                }
                guard !Task.isCancelled else { return }
                await rebuildFilteredCatalog()
            }
            .onChange(of: premiumFilter.stamp) { _, _ in
                Task {
                    await viewModel.fetchSources(sources, refresh: true)
                    await rebuildAppCatalog()
                }
            }
            .onChange(of: privacyManager.hiddenAppUUIDs) { _, _ in
                Task { await rebuildAppCatalog() }
            }
            .onChange(of: privacyManager.strictHidingEnabled) { _, _ in
                Task { await rebuildAppCatalog() }
            }
            .onChange(of: privacyManager.isRevealingHiddenApps) { _, _ in
                Task { await rebuildAppCatalog() }
            }
            // Deleting a repository (swipe, context menu, Sources tab) while a
            // refresh runs must not leave faulted managed objects behind in
            // the catalog dictionary — that was an App Store crash path.
            .onReceive(viewModel.$sources.dropFirst()) { _ in
                Task { await rebuildAppCatalog() }
            }
            .onChange(of: sources.count) { _, _ in
                viewModel.evictDeletedSources(valid: Array(sources))
            }
        }
    }

    // MARK: - Toolbar Content
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                NavigationLink {
                    SourcePriorityView(sources: Array(sources))
                } label: {
                    Image(systemName: "list.number")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel(Text(.localized("Repository Priority")))

                Button {
                    isAddingPresenting = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel(Text(.localized("Add Source")))

                // Profile / Settings Menu (styled like App Store Account button)
                Menu {
                    Section(.localized("Updates")) {
                        // Keep menu actions local to this tab. NavigationLinks inside
                        // a toolbar Menu are not consistently routed by TabView and
                        // were one of the reasons the store controls appeared dead.
                        Button {
                            withAnimation(.snappy) {
                                selectedSegment = .updates
                                searchText = ""
                            }
                        } label: {
                            Label(updateCount > 0 ? String.localized("Pending Updates (%lld)", arguments: updateCount) : .localized("Pending Updates"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button {
                            withAnimation(.snappy) {
                                selectedSegment = .repositories
                                searchText = ""
                            }
                        } label: {
                            Label(.localized("Manage Repositories"), systemImage: "shippingbox")
                        }
                    }

                    Section(.localized("Sources")) {
                        Button {
                            Task { await viewModel.fetchSources(sources, refresh: true) }
                        } label: {
                            Label(.localized("Refresh All Sources"), systemImage: "arrow.clockwise")
                        }
                        Button {
                            withAnimation(.snappy) {
                                selectedSegment = .repositories
                                searchText = ""
                            }
                        } label: {
                            Label(.localized("Source Health"), systemImage: "heart.text.clipboard")
                        }
                    }
                } label: {
                    VexBrandLogo()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                }
            }
        }

        ToolbarItem(placement: .topBarLeading) {
            if updateCount > 0 {
                NavigationLink(destination: UpdatesView()) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("\(updateCount)").font(.caption2.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.userTint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .foregroundStyle(Color.userTint)
                }
            }
        }
    }

    // MARK: - Apple App Store Date & Editorial Header
    private var headerTodayDate: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(todayDateFormatted)
                    .font(.caption.weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 8) {
                    Text(.localized("App Store"))
                        .font(.title2.weight(.bold))
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(.localized("On-device"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if !viewModel.isFinished {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 4)
    }

    private var todayDateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    /// Banner shown while some repositories are being served from the offline
    /// snapshot cache. Browsing keeps working; data may be outdated.
    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(.localized("Showing Saved Copies"))
                    .font(.subheadline.weight(.semibold))
                Text(.localized("Some repositories couldn't be refreshed. You're browsing the last saved copy."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                Task {
                    await viewModel.fetchSources(sources, refresh: true)
                    await rebuildAppCatalog()
                }
            } label: {
                Text(.localized("Retry"))
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Apple Style Segmented Filter Pills
    private var segmentPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StoreSegment.allCases) { seg in
                    let isSelected = selectedSegment == seg
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            selectedSegment = seg
                            // A segment is a real destination, not a filter on
                            // the current search result. Clear search so every
                            // App Store tab remains reachable after searching.
                            searchText = ""
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if seg == .updates && updateCount > 0 {
                                Text("\(updateCount)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(isSelected ? .white.opacity(0.25) : Color.userTint, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            Text(seg.rawValue)
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(isSelected ? Color.userTint : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                        .foregroundStyle(isSelected ? .white : .primary)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.08), lineWidth: 1))
                    }
                    .buttonStyle(VexSignFlareButtonStyle())
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Discover Section (Apple Official Today View)
    @ViewBuilder
    private var discoverSection: some View {
        VStack(spacing: 24) {
            // Apple Today Hero Editorial Card
            heroTodayCard

            // Updates alert if available
            if updateCount > 0 {
                updatesNotificationCard
            }

            // Must-Have Utilities & Tweaks Shelf (Apple horizontal carousel)
            mustHaveShelf

            // Top Free Sideloaded Apps (Apple ranked 3-row charts)
            topAppsRankedSection

            // Merged Repositories Master Card
            allRepositoriesBannerCard
        }
    }

    // MARK: Hero Editorial Today Card
    private var heroTodayCard: some View {
        let featuredItem = allSourcedApps.first

        return ZStack(alignment: .bottomLeading) {
            // Vibrant Apple-style gradient with depth
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.36, blue: 0.95),
                    Color(red: 0.20, green: 0.52, blue: 1.0),
                    Color(red: 0.45, green: 0.20, blue: 0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 12) {
                // Eyebrow badge
                HStack(spacing: 6) {
                    VexBrandLogo()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text("FEATURED ON VEXSIGN")
                        .font(.caption2.weight(.heavy))
                        .tracking(1.0)
                        .foregroundStyle(.white.opacity(0.9))
                }

                // Main headline
                VStack(alignment: .leading, spacing: 4) {
                    Text(featuredItem?.app.currentName ?? "Discover & Sideload")
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(featuredItem?.app.currentDescription ?? "Sign & install any iOS app on-device without PC or revocations.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                }

                Spacer(minLength: 16)

                // Bottom App Bar with GET button & repo logo badge
                if let item = featuredItem {
                    NavigationLink(destination: SourceAppsDetailView(source: item.repository, app: item.app)) {
                        HStack(spacing: 12) {
                            ZStack(alignment: .bottomTrailing) {
                                AppStoreIconView(app: item.app, size: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                                // Repo logo badge
                                RepoMiniBadge(source: item.source)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.app.currentName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(item.sourceName.isEmpty ? .localized("Repository") : item.sourceName)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .lineLimit(1)
                            }

                            Spacer()

                            DownloadButtonView(app: item.app)
                                .tint(.white)
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "globe.desk.fill")
                        Text("\(nonExcludedSources.count) sources connected")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(18)
        }
        .frame(minHeight: 250)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color(red: 0.04, green: 0.36, blue: 0.95).opacity(0.28), radius: 18, y: 10)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    // MARK: Must-Have Utilities & Tweaks Shelf
    @ViewBuilder
    private var mustHaveShelf: some View {
        let items = Array(allSourcedApps.prefix(8))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Must-Have Apps"))
                            .font(.title3.weight(.bold))
                        Text(.localized("Hand-picked community essentials"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation { selectedSegment = .apps }
                    } label: {
                        Text(.localized("See All"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.userTint)
                    }
                }
                .padding(.horizontal, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(items) { item in
                            NavigationLink(destination: SourceAppsDetailView(source: item.repository, app: item.app)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .bottomTrailing) {
                                        AppStoreIconView(app: item.app, size: 76)
                                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                                            .shadow(color: Color.black.opacity(0.08), radius: 6, y: 3)

                                        // Repo logo badge
                                        RepoMiniBadge(source: item.source)
                                            .offset(x: 4, y: 4)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.app.currentName)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Text(item.app.currentDescription ?? item.sourceName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    DownloadButtonView(app: item.app)
                                }
                                .frame(width: 100)
                                .padding(10)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    // MARK: Top Apps Ranked List (Apple 3-Row Style)
    @ViewBuilder
    private var topAppsRankedSection: some View {
        let topList = Array(allSourcedApps.prefix(9))
        if !topList.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Top Free Apps"))
                            .font(.title3.weight(.bold))
                        Text(.localized("Popular across all repositories"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation { selectedSegment = .apps }
                    } label: {
                        Text(.localized("See All"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.userTint)
                    }
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(Array(topList.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(destination: SourceAppsDetailView(source: item.repository, app: item.app)) {
                            HStack(spacing: 12) {
                                // Ranking number
                                Text("\(index + 1)")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .center)

                                ZStack(alignment: .bottomTrailing) {
                                    AppStoreIconView(app: item.app, size: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

                                    RepoMiniBadge(source: item.source)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.app.currentName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text(item.app.currentDescription ?? item.sourceName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    if let ver = item.app.currentVersion {
                                        Text(ver)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer(minLength: 8)

                                DownloadButtonView(app: item.app)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < topList.count - 1 {
                            Divider().padding(.leading, 84).opacity(0.5)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }

    // MARK: All Repositories Master Card
    private var allRepositoriesBannerCard: some View {
        NavigationLink {
            SourceAppsView(object: nonExcludedSources, viewModel: viewModel, onRefresh: {
                await viewModel.fetchSources(sources, refresh: true)
            })
        } label: {
            HStack(spacing: 14) {
                Image("Repositories")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(.localized("All Repositories"))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(verbatim: String.localized("%lld sources • %lld apps available", arguments: nonExcludedSources.count, allSourcedApps.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Apps Catalog Section (Ksign App Store Catalog)
    private var appsCatalogSection: some View {
        VStack(spacing: 16) {
            // Category filter pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(appCategories, id: \.self) { cat in
                        let isSel = selectedCategory == cat
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                selectedCategory = cat
                            }
                        } label: {
                            Text(cat)
                                .font(.caption.weight(isSel ? .bold : .medium))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(isSel ? Color.userTint : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                                .foregroundStyle(isSel ? .white : .primary)
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(isSel ? 0 : 0.08), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            // Sort bar & count header
            HStack {
                Text(verbatim: String.localized("%lld Apps Available", arguments: sortedAndFilteredApps.count))
                    .font(.headline)
                Spacer()
                Menu {
                    Picker("Sort by", selection: $appSortOption) {
                        ForEach(AppSortOption.allCases, id: \.self) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(appSortOption.rawValue)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color(uiColor: .quaternarySystemFill), in: Capsule())
                    .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 4)

            if sortedAndFilteredApps.isEmpty {
                emptyAppsView
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(sortedAndFilteredApps) { item in
                        NavigationLink(destination: SourceAppsDetailView(source: item.repository, app: item.app)) {
                            HStack(spacing: 12) {
                                ZStack(alignment: .bottomTrailing) {
                                    AppStoreIconView(app: item.app, size: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

                                    RepoMiniBadge(source: item.source)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.app.currentName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text(item.app.currentDescription ?? item.sourceName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        if let ver = item.app.currentVersion {
                                            Text("v\(ver)").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        if let size = item.app.size, size > 0 {
                                            Text("• \(size.formattedByteCount)").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Text("• \(item.sourceName)").font(.caption2).foregroundStyle(Color.userTint).lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 8)

                                DownloadButtonView(app: item.app)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().padding(.leading, 78).opacity(0.5)
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }

    private var sourceHealthCard: some View {
        let health = sourceHealth
        let attentionCount = health.failed + health.stale + health.neverFetched
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(Color.userTint)
                Text(.localized("Source Health"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String.localized("%lld total", arguments: sources.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                sourceHealthPill(String.localized("%lld healthy", arguments: health.healthy), color: .green)
                sourceHealthPill(String.localized("%lld failed", arguments: health.failed), color: health.failed > 0 ? .red : .secondary)
                sourceHealthPill(String.localized("%lld needs refresh", arguments: health.stale + health.neverFetched), color: attentionCount > 0 ? .orange : .secondary)
            }

            if attentionCount > 0 {
                Button {
                    Task { await viewModel.fetchSources(sources, refresh: true) }
                } label: {
                    Label(.localized("Refresh All Sources"), systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.userTint)
            }

            if let latest = sources.compactMap({
                SourcePreferences.lastFetch(for: $0.identifier ?? $0.sourceURL?.absoluteString ?? "")
            }).max() {
                Text(String.localized("Last refresh %@", arguments: latest.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func sourceHealthPill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.13), in: Capsule())
    }

    // MARK: - Repositories Section (merged into App Store)
    private var repositoriesSection: some View {
        VStack(spacing: 16) {
            // Repositories summary header
            HStack {
                Text(.localized("Sources & Repositories"))
                    .font(.headline)
                Spacer()
                Menu {
                    Picker(.localized("Sort Repositories"), selection: $_repositorySortRaw) {
                        ForEach(RepositorySortOption.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.userTint)
                }
                Button {
                    isAddingPresenting = true
                } label: {
                    Label(.localized("Add Source"), systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.userTint, in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(Text(.localized("Add Source")))

                NavigationLink {
                    SourceHealthDashboardView()
                } label: {
                    Image(systemName: "heart.text.clipboard")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.userTint)
                }
                .accessibilityLabel(Text(.localized("Source Health")))
            }
            .padding(.horizontal, 4)

            sourceHealthCard

            // Master "All Repositories" Card
            allRepositoriesBannerCard

            // Repositories List
            if filteredSources.isEmpty {
                NBContentUnavailable(.localized("No Repositories"), systemImage: "bag.fill", description: .localized("Get started by adding community repositories.")) {
                    Button { isAddingPresenting = true } label: { Label(.localized("Add Source"), systemImage: "plus") }
                        .buttonStyle(.borderedProminent).tint(Color.userTint)
                }
                .padding(.vertical, 20)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredSources.enumerated()), id: \.element.objectID) { index, source in
                        NavigationLink {
                            SourceAppsView(object: [source], viewModel: viewModel, onRefresh: {
                                await viewModel.fetchSources(sources, refresh: true)
                            })
                        } label: {
                            RepositoryRow(source: source, repository: viewModel.sources[source], isStale: viewModel.isStale(source))
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Storage.shared.deleteSource(for: source)
                            } label: {
                                Label(.localized("Delete"), systemImage: "trash")
                            }
                        }

                        if index < filteredSources.count - 1 {
                            Divider().padding(.leading, 74).opacity(0.5)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }

            // Community Directory (1-Tap Add)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Community Directory"))
                            .font(.headline)
                        Text(.localized("Tap Add to add verified community repositories"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(Array(communityRepos.enumerated()), id: \.element.id) { index, item in
                        let isAdded = nonExcludedSources.contains { $0.sourceURL?.absoluteString == item.url.absoluteString || ($0.identifier ?? "") == item.url.absoluteString }
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.userTint.opacity(0.12))
                                    .frame(width: 40, height: 40)
                                Image(systemName: item.iconName)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.userTint)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(item.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button {
                                if !isAdded {
                                    Storage.shared.addSource(item.url, name: item.name, identifier: item.url.absoluteString) { err in
                                        if err == nil {
                                            Toast.success(String.localized("Added %@", arguments: item.name), systemImage: "checkmark.circle.fill")
                                            Task { await viewModel.fetchSources(sources, refresh: true) }
                                        }
                                    }
                                }
                            } label: {
                                Text(isAdded ? .localized("ADDED") : .localized("ADD"))
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(isAdded ? Color.secondary.opacity(0.15) : Color.userTint, in: Capsule())
                                    .foregroundStyle(isAdded ? Color.secondary : Color.white)
                            }
                            .buttonStyle(.plain)
                            .disabled(isAdded)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)

                        if index < communityRepos.count - 1 {
                            Divider().padding(.leading, 66).opacity(0.5)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }
        }
    }

    // MARK: - Updates Section
    private var updatesSection: some View {
        VStack(spacing: 16) {
            updatesNotificationCard

            NavigationLink(destination: UpdateMatchingSettingsView()) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.userTint.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.userTint)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Update Matching Rules"))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("Configure name matching, beta filters & developers"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if updateCount > 0 {
                NavigationLink(destination: UpdatesView()) {
                    HStack {
                        Label(.localized("View All Pending Updates"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(Color.userTint)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.userTint)
                    Text(.localized("All Apps Are Up to Date"))
                        .font(.headline)
                    Text(.localized("Your installed applications are on the latest versions from your sources."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var updatesNotificationCard: some View {
        NavigationLink(destination: UpdatesView()) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.userTint.opacity(0.14)).frame(width: 44, height: 44)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.userTint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(.localized("Updates Available"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(verbatim: updateCount == 1 ? String.localized("1 app has an update") : String.localized("%lld apps have updates", arguments: updateCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(.localized("UPDATE ALL"))
                    .font(.caption.weight(.heavy))
                    .tracking(0.4)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.userTint, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search Results View
    @ViewBuilder
    private var searchResultsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !sortedAndFilteredApps.isEmpty {
                Text(verbatim: String.localized("%lld Matching Apps", arguments: sortedAndFilteredApps.count))
                    .font(.headline)
                    .padding(.horizontal, 4)

                LazyVStack(spacing: 0) {
                    ForEach(sortedAndFilteredApps) { item in
                        NavigationLink(destination: SourceAppsDetailView(source: item.repository, app: item.app)) {
                            HStack(spacing: 12) {
                                ZStack(alignment: .bottomTrailing) {
                                    AppStoreIconView(app: item.app, size: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    RepoMiniBadge(source: item.source)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.app.currentName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.app.currentDescription ?? item.sourceName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                DownloadButtonView(app: item.app)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().padding(.leading, 74).opacity(0.5)
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }

            if !filteredSources.isEmpty {
                Text(verbatim: String.localized("%lld Matching Sources", arguments: filteredSources.count))
                    .font(.headline)
                    .padding(.horizontal, 4)

                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredSources.enumerated()), id: \.element.objectID) { index, source in
                        NavigationLink {
                            SourceAppsView(object: [source], viewModel: viewModel, onRefresh: {
                                await viewModel.fetchSources(sources, refresh: true)
                            })
                        } label: {
                            RepositoryRow(source: source, repository: viewModel.sources[source], isStale: viewModel.isStale(source))
                        }
                        .buttonStyle(.plain)

                        if index < filteredSources.count - 1 {
                            Divider().padding(.leading, 74).opacity(0.5)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }

            if sortedAndFilteredApps.isEmpty && filteredSources.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text(verbatim: String.localized("No results for “%@”", arguments: searchText))
                        .font(.headline)
                    Text(.localized("Check the spelling or try searching for another app or repository."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var emptyAppsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(.localized("No Apps Found"))
                .font(.headline)
            Text(.localized("Make sure you have added repositories, or pull to refresh."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                isAddingPresenting = true
            } label: {
                Label(.localized("Add Source"), systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.userTint)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Footer: Activity Logs Link (Moved to Settings)
    private var logsMovedFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(.localized("Logs have moved to Settings → Activity Logs for a single navigation bar."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            NavigationLink(destination: LogsHistoryView(inNavigationStack: false)) {
                Label(.localized("View Activity Logs"), systemImage: "text.alignleft")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.userTint)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
