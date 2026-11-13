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
    @ObservedObject var viewModel = SourcesViewModel.shared
    @ObservedObject private var updateChecker = AppUpdateChecker.shared
    @ObservedObject private var premiumFilter = PremiumFilterPreferences.shared
    @ObservedObject private var privacyManager = AppLockManager.shared

    @FetchRequest(entity: Signed.entity(), sortDescriptors: [])
    private var signedApps: FetchedResults<Signed>

    @FetchRequest(entity: Imported.entity(), sortDescriptors: [])
    private var importedApps: FetchedResults<Imported>

    @State var searchText = ""
    @State var selectedSegment: StoreSegment = .discover
    @State var isAddingPresenting = false
    @State private var appSortOption: AppSortOption = .name
    @State private var selectedCategory: String = "All"
    @State private var catalogItems: [SourcedAppItem] = []
    @State private var filteredCatalogItems: [SourcedAppItem] = []
    @State private var catalogRevision = 0
    @State private var catalogBuildGeneration = 0
    @State private var catalogFilterGeneration = 0
    @AppStorage("VexSign.repositorySort") var _repositorySortRaw = RepositorySortOption.priority.rawValue

    private let appCategories = ["All", "Utilities", "Emulators", "Tweaked", "Games", "Jailbreak"]

    let communityRepos: [CommunityRepoItem] = [
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
    ) var sources: FetchedResults<AltSource>

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

    var nonExcludedSources: [AltSource] {
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

    var filteredSources: [AltSource] {
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
    var allSourcedApps: [SourcedAppItem] { catalogItems }
    private var sortedAndFilteredApps: [SourcedAppItem] { filteredCatalogItems }

    @MainActor
    func rebuildAppCatalog() async {
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

    var updateCount: Int { updateChecker.updateCount }

    /// Internal, not private: `sourceHealthCard` renders it from
    /// AppStoreView+Repositories.swift, and a private type cannot be the type of
    /// a non-private property.
    struct SourceHealthSummary {
        let healthy: Int
        let failed: Int
        let stale: Int
        let neverFetched: Int
    }

    var sourceHealth: SourceHealthSummary {
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
        NBNavigationView(.localized("Discover"), displayMode: .large) {
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
