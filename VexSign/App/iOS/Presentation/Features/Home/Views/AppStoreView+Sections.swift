//
//  AppStoreView+Sections.swift
//  VexSign
//
//  The app store's sections, separated from the view that owns their state.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

extension AppStoreView {
    // MARK: - Apps Catalog Section
    var appsCatalogSection: some View {
        VStack(spacing: 16) {
            // Category filter pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(appCategories, id: \.self) { cat in
                        let isSel = selectedCategory == cat
                        Button {
                            withAppAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
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

                                DownloadButtonView(app: item.app, originURL: item.source.sourceURL)
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
    var searchResultsView: some View {
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
                                DownloadButtonView(app: item.app, originURL: item.source.sourceURL)
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
                    ForEach(Array(filteredSources.enumerated()), id: \.element.id) { index, source in
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
    var logsMovedFooter: some View {
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
