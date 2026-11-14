//
//  SourceHealthDashboardView.swift
//  VexSign
//
//  Source health dashboard: last successful refresh, failure reason, retry
//  count, rate-limit status, repository priority and duplicate-app
//  resolution, all in one place (App Store → Repositories → Source Health).
//

import SwiftUI
import NimbleViews
import CoreData
import NimbleExtensions

struct SourceHealthDashboardView: View {
	@ObservedObject private var viewModel = SourcesViewModel.shared
	@ObservedObject private var updateChecker = AppUpdateChecker.shared

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var sources: FetchedResults<AltSource>

	@State private var isRefreshing = false

	var body: some View {
		NBNavigationView(.localized("Source Health"), displayMode: .inline) {
			ScrollView {
				VStack(spacing: 16) {
					summaryCard
					duplicateResolutionCard

					if sources.isEmpty {
						NBContentUnavailable(
							.localized("No Repositories"),
							systemImage: "globe.desk",
							description: .localized("Add a repository to see its health here.")
						)
						.padding(.vertical, 28)
					} else {
						VStack(spacing: 0) {
							ForEach(Array(orderedSources.enumerated()), id: \.element.objectID) { index, source in
								row(for: source)
								if index < orderedSources.count - 1 {
									Divider().padding(.leading, 66).opacity(0.5)
								}
							}
						}
						.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
						.overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
					}
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 12)
			}
			.background(Theme.background)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						Task {
							isRefreshing = true
							await viewModel.fetchSources(sources, refresh: true)
							isRefreshing = false
						}
					} label: {
						if isRefreshing {
							ProgressView().controlSize(.small)
						} else {
							Image(systemName: "arrow.clockwise")
						}
					}
					.disabled(isRefreshing)
					.accessibilityLabel(Text(.localized("Refresh All Sources")))
				}
			}
		}
	}

	// MARK: - Ordering

	private var orderedSources: [AltSource] {
		let array = Array(sources)
		let ids = array.map { $0.identifier ?? $0.sourceURL?.absoluteString ?? "" }
		let order = SourcePreferences.order(for: ids)
		return array.sorted {
			let lhsID = $0.identifier ?? $0.sourceURL?.absoluteString ?? ""
			let rhsID = $1.identifier ?? $1.sourceURL?.absoluteString ?? ""
			let lhs = order.firstIndex(of: lhsID) ?? Int.max
			let rhs = order.firstIndex(of: rhsID) ?? Int.max
			if lhs != rhs { return lhs < rhs }
			return ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
		}
	}

	private func identifier(for source: AltSource) -> String {
		source.identifier ?? source.sourceURL?.absoluteString ?? source.objectID.uriRepresentation().absoluteString
	}

	// MARK: - Summary

	private var summaryCard: some View {
		let healths = orderedSources.map { SourcePreferences.health(for: identifier(for: $0)) }
		let healthy = healths.filter { $0.lastError == nil && !$0.isRateLimited }.count
		let failing = healths.filter { $0.lastError != nil && !$0.isRateLimited }.count
		let limited = healths.filter { $0.isRateLimited }.count
		let stale = viewModel.staleSourceIDs.count

		return VStack(alignment: .leading, spacing: 12) {
			Label(.localized("Overview"), systemImage: "heart.text.clipboard")
				.font(.headline)
				.accessibilityAddTraits(.isHeader)
				.padding(.top, 4)

			HStack(spacing: 10) {
				summaryTile(.localized("Healthy"), value: healthy, icon: "checkmark.circle.fill", tint: .green)
				summaryTile(.localized("Failing"), value: failing, icon: "exclamationmark.triangle.fill", tint: .orange)
				summaryTile(.localized("Rate Limited"), value: limited, icon: "hourglass", tint: .purple)
				summaryTile(.localized("Stale"), value: stale, icon: "clock.badge.exclamationmark", tint: .blue)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
		.accessibilityElement(children: .combine)
		.accessibilityLabel(Text(verbatim: String.localized(
			"Healthy %lld, Failing %lld, Rate limited %lld, Stale %lld",
			arguments: healthy, failing, limited, stale
		)))
	}

	private func summaryTile(_ title: String, value: Int, icon: String, tint: Color) -> some View {
		VStack(spacing: 6) {
			Image(systemName: icon)
				.font(.system(size: 16, weight: .semibold))
				.foregroundStyle(tint)
			Text("\(value)")
				.font(.headline.monospacedDigit())
			Text(title)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.minimumScaleFactor(0.7)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 10)
		.background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.accessibilityHidden(true)
	}

	// MARK: - Duplicates

	private var duplicateResolutionCard: some View {
		let duplicates = duplicateBundleIDs

		return VStack(alignment: .leading, spacing: 10) {
			Label(.localized("Duplicate Apps"), systemImage: "square.stack.3d.up.slash")
				.font(.headline)
				.accessibilityAddTraits(.isHeader)

			if duplicates.isEmpty {
				Text(.localized("No two repositories publish the same bundle identifier. When they do, the higher-priority source wins."))
					.font(.caption)
					.foregroundStyle(.secondary)
			} else {
				Text(verbatim: String.localized(
					"%lld bundle identifiers are published by more than one repository. Higher-priority repositories win:",
					arguments: duplicates.count
				))
					.font(.caption)
					.foregroundStyle(.secondary)
				ForEach(duplicates.prefix(8), id: \.self) { bundleID in
					let publishers = sourcesPublishing(bundleID)
					VStack(alignment: .leading, spacing: 3) {
						Text(bundleID)
							.font(.caption.weight(.semibold))
							.foregroundStyle(Color.userTint)
						ForEach(publishers, id: \.self) { name in
							Label(name, systemImage: "checkmark.seal")
								.font(.caption2)
								.foregroundStyle(.secondary)
								.labelStyle(.titleAndIcon)
						}
					}
					.padding(.top, 4)
				}
				if duplicates.count > 8 {
					Text(verbatim: String.localized("+ %lld more", arguments: duplicates.count - 8))
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
	}

	private var duplicateBundleIDs: [String] {
		var seen: Set<String> = []
		var duplicated: Set<String> = []
		for entry in viewModel.sources {
			for app in entry.value.apps {
				guard let id = app.id, !id.isEmpty else { continue }
				if seen.contains(id) {
					duplicated.insert(id)
				} else {
					seen.insert(id)
				}
			}
		}
		return duplicated.sorted()
	}

	private func sourcesPublishing(_ bundleID: String) -> [String] {
		var names: [String] = []
		for source in orderedSources {
			guard let repo = viewModel.sources[source] else { continue }
			if repo.apps.contains(where: { $0.id == bundleID }) {
				names.append(source.name ?? identifier(for: source))
			}
		}
		return names
	}

	// MARK: - Rows

	private func row(for source: AltSource) -> some View {
		let id = identifier(for: source)
		let health = SourcePreferences.health(for: id)
		let isStale = viewModel.staleSourceIDs.contains(id)

		return VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 12) {
				ZStack {
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.fill(statusColor(health: health, isStale: isStale).opacity(0.14))
						.frame(width: 40, height: 40)
					Image(systemName: statusIcon(health: health, isStale: isStale))
						.font(.system(size: 17, weight: .semibold))
						.foregroundStyle(statusColor(health: health, isStale: isStale))
				}

				VStack(alignment: .leading, spacing: 2) {
					Text(source.name ?? .localized("Repository"))
						.font(.subheadline.weight(.semibold))
						.lineLimit(1)
					Text(statusLine(health: health, isStale: isStale))
						.font(.caption2)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}

				Spacer(minLength: 8)

				VStack(alignment: .trailing, spacing: 3) {
					if let priority = priorityIndex(of: source) {
						Text(verbatim: String.localized("#%lld", arguments: priority + 1))
							.font(.caption2.weight(.semibold).monospacedDigit())
							.foregroundStyle(.secondary)
					}
					if health.consecutiveFailures > 0 {
						Text(verbatim: String.localized("%lld retries", arguments: health.consecutiveFailures))
							.font(.caption2.monospacedDigit())
							.foregroundStyle(.orange)
					}
				}
			}

			if let error = health.lastError {
				Label(error, systemImage: "exclamationmark.bubble")
					.font(.caption2)
					.foregroundStyle(.orange)
					.lineLimit(2)
					.padding(.leading, 52)
			}
			if health.isRateLimited, let until = health.rateLimitedUntil {
				Label(
					String.localized("Paused until %@ (rate limited)", arguments: until.formatted(date: .omitted, time: .shortened)),
					systemImage: "hourglass"
				)
				.font(.caption2)
				.foregroundStyle(.purple)
				.padding(.leading, 52)
			}
			if let next = health.nextRetryDate {
				Label(
					String.localized("Next automatic retry: %@", arguments: next.formatted(date: .omitted, time: .shortened)),
					systemImage: "clock.arrow.circlepath"
				)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.padding(.leading, 52)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.accessibilityElement(children: .combine)
	}

	private func priorityIndex(of source: AltSource) -> Int? {
		let id = identifier(for: source)
		let ids = orderedSources.map { identifier(for: $0) }
		let order = SourcePreferences.order(for: ids)
		return order.firstIndex(of: id)
	}

	private func statusColor(health: SourcePreferences.Health, isStale: Bool) -> Color {
		if health.isRateLimited { return .purple }
		if health.lastError != nil { return .orange }
		if isStale { return .blue }
		return .green
	}

	private func statusIcon(health: SourcePreferences.Health, isStale: Bool) -> String {
		if health.isRateLimited { return "hourglass" }
		if health.lastError != nil { return "exclamationmark.triangle.fill" }
		if isStale { return "clock.badge.exclamationmark" }
		return "checkmark.circle.fill"
	}

	private func statusLine(health: SourcePreferences.Health, isStale: Bool) -> String {
		if let success = health.lastSuccess {
			let base = String.localized("Last refreshed %@", arguments: success.formatted(.relative(presentation: .named)))
			return isStale ? base + " • " + String.localized("Showing saved copy") : base
		}
		if health.lastAttempt != nil {
			return .localized("Never refreshed successfully")
		}
		return .localized("Not refreshed yet")
	}
}
