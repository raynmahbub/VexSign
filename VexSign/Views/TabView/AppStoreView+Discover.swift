//
//  AppStoreView+Discover.swift
//  VexSign
//
//  Editorial Today header, segment pills and the Discover shelves.
//
//  Split out of AppStoreView.swift; behaviour is unchanged.
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import NukeUI
import CoreData
import AltSourceKit

extension AppStoreView {
    // MARK: - Apple App Store Date & Editorial Header
    var headerTodayDate: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(todayDateFormatted)
                    .font(.caption.weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 8) {
                    Text(.localized("Discover"))
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
        DiscoverHeaderDate.formatter.string(from: Date())
    }

    /// Banner shown while some repositories are being served from the offline
    /// snapshot cache. Browsing keeps working; data may be outdated.
    var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(.localized("Showing Saved Copies"))
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: RepositoryRefreshNotice.message(
                    naming: sources.filter { viewModel.isStale($0) }.map { RepositoryRefreshNotice.displayName(for: $0) }
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    var segmentPills: some View {
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
    var discoverSection: some View {
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
                    Text(.localized("FEATURED ON VEXSIGN"))
                        .font(.caption2.weight(.heavy))
                        .tracking(1.0)
                        .foregroundStyle(.white.opacity(0.9))
                }

                // Main headline
                VStack(alignment: .leading, spacing: 4) {
                    Text(featuredItem?.app.currentName ?? .localized("Discover & Sideload"))
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(featuredItem?.app.currentDescription ?? .localized("Sign & install any iOS app on-device without PC or revocations."))
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
                        Text(String.localized("%lld sources connected", arguments: nonExcludedSources.count))
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
    var allRepositoriesBannerCard: some View {
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
}

/// The header's date formatter, built once. The header is re-evaluated on every state change
/// of the Discover screen, and constructing a `DateFormatter` each time is avoidable work.
/// Read on the main thread only, by the view body.
private enum DiscoverHeaderDate {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter
    }()
}

/// Names the repositories behind the "Showing Saved Copies" banner.
///
/// The banner used to say only that "some repositories" could not be refreshed, with every
/// repository's own reason one screen away in Source Health. The names come from the same
/// stale set that marks the rows; the reasons stay in Source Health, which already records
/// them per repository.
enum RepositoryRefreshNotice {
    /// How many repositories are named before the rest are counted.
    static let namedLimit = 2

    static func message(naming names: [String]) -> String {
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            return .localized("Some repositories couldn't be refreshed. You're browsing the last saved copy.")
        }
        let named = cleaned.prefix(namedLimit).joined(separator: ", ")
        let remaining = cleaned.count - min(cleaned.count, namedLimit)
        if remaining == 0 {
            return .localized("Couldn't refresh %@. Showing the last saved copy. See Source Health for the reason.", arguments: named)
        }
        return .localized(
            "Couldn't refresh %@ and %lld more. Showing the last saved copy. See Source Health for the reasons.",
            arguments: named, remaining
        )
    }

    static func displayName(for source: AltSource) -> String {
        if let name = source.name, !name.isEmpty { return name }
        return source.sourceURL?.host ?? source.sourceURL?.absoluteString ?? ""
    }
}
