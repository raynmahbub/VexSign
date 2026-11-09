//
//  AppStoreView+Repositories.swift
//  VexSign
//
//  Source health, the repository list and the updates section.
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
    var repositoriesSection: some View {
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
    var updatesSection: some View {
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

    var updatesNotificationCard: some View {
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
}
