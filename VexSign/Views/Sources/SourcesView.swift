//
//  SourcesView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 10.04.2025.
//
import CoreData
import AltSourceKit
import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - View
struct SourcesView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.scenePhase) private var scenePhase
	#if !NIGHTLY && !DEBUG
	@AppStorage("VexSign.shouldStar") private var _shouldStar: Int = 0
	#endif
	@StateObject var viewModel = SourcesViewModel.shared
	@State private var _isAddingPresenting = false
	@State private var _addingSourceLoading = false
	@State private var _searchText = ""
	@State private var _shouldNavigateToAllRepos = false
	@State private var _activeIndividualSource: AltSource?
	@State private var _isEditMode = false
	@State private var _selectedSources: Set<AltSource> = []
	@State private var _showDeleteConfirmation = false

	private var _sourceOrder: [String] {
		SourcePreferences.order(for: _sources.map { $0.identifier ?? $0.sourceURL?.absoluteString ?? "" })
	}

	@AppStorage("VexSign.sourcesTabShowAllReposDirectly")
	private var _sourcesTabShowAllReposDirectly: Bool = false

	/// Sources not excluded from "All Repositories"
	private var _nonExcludedSources: [AltSource] {
		let visible = _sources.filter { source in
			let id = source.identifier ?? source.sourceURL?.absoluteString ?? ""
			return !VexSignAPI.isSourceExcluded(id)
		}
		let priorities = _sourceOrder.enumerated().reduce(into: [String: Int]()) { result, item in
			result[item.element] = item.offset
		}
		return visible.sorted {
			let lhs = priorities[$0.identifier ?? $0.sourceURL?.absoluteString ?? ""] ?? Int.max
			let rhs = priorities[$1.identifier ?? $1.sourceURL?.absoluteString ?? ""] ?? Int.max
			if lhs != rhs { return lhs < rhs }
			return ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
		}
	}

	@ObservedObject var appNavigationManager = AppNavigationManager.shared
	@ObservedObject private var _premiumFilter = PremiumFilterPreferences.shared

	private var _filteredSources: [AltSource] {
		let filtered = _sources.filter { _searchText.isEmpty || ($0.name?.localizedCaseInsensitiveContains(_searchText) ?? false) }
		let priorities = _sourceOrder.enumerated().reduce(into: [String: Int]()) { result, item in
			result[item.element] = item.offset
		}
		return filtered.sorted { lhs, rhs in
			let lid = lhs.identifier ?? lhs.sourceURL?.absoluteString ?? ""
			let rid = rhs.identifier ?? rhs.sourceURL?.absoluteString ?? ""
			let lp = SourcePreferences.isPinned(lid)
			let rp = SourcePreferences.isPinned(rid)
			if lp != rp { return lp && !rp }
			let lPriority = priorities[lid] ?? Int.max
			let rPriority = priorities[rid] ?? Int.max
			if lPriority != rPriority { return lPriority < rPriority }
			return (lhs.name ?? "").localizedCaseInsensitiveCompare(rhs.name ?? "") == .orderedAscending
		}
	}

	private struct SourceHealthSummary {
		let healthy: Int
		let failed: Int
		let stale: Int
		let neverFetched: Int
	}

	private var _health: SourceHealthSummary {
		let staleAfter: TimeInterval = 24 * 60 * 60
		var healthy = 0
		var failed = 0
		var stale = 0
		var neverFetched = 0

		for source in _sources {
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

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Sources")) {
            mainContent
                .navigationDestination(isPresented: $_shouldNavigateToAllRepos) {
                    SourceAppsView(object: _nonExcludedSources, viewModel: viewModel, onRefresh: {
                        await viewModel.fetchSources(_sources, refresh: true)
                    })
                }
                .navigationDestination(isPresented: Binding(
                    get: { _activeIndividualSource != nil },
                    set: { if !$0 { _activeIndividualSource = nil } }
                )) {
                    if let source = _activeIndividualSource {
                        SourceAppsView(object: [source], viewModel: viewModel, onRefresh: {
                            await viewModel.fetchSources(_sources, refresh: true)
                        })
                    }
                }
		}
		.task(id: Array(_sources)) {
			await viewModel.fetchSources(_sources)
		}
		.nbOnChange(of: appNavigationManager.pendingAppNavigation) { pendingNavigation in
			handlePendingNavigation(pendingNavigation)
		}
		.nbOnChange(of: _isEditMode) { isEditing in
			if !isEditing {
				_selectedSources.removeAll()
			}
		}
		.nbOnChange(of: _premiumFilter.stamp) { _ in
			Task {
				await viewModel.fetchSources(_sources, refresh: true)
			}
		}
		.nbOnChange(of: scenePhase) { newPhase in
			if newPhase == .active {
				Task {
					await viewModel.fetchSources(_sources)
				}
			}
		}
	}

	@ViewBuilder
	private var mainContent: some View {
		if _sourcesTabShowAllReposDirectly && !_filteredSources.isEmpty {
			allRepositoriesDirectView
		} else {
			sourcesListView
		}
	}

	@ViewBuilder
	private var allRepositoriesDirectView: some View {
		SourceAppsView(
			object: _nonExcludedSources,
			viewModel: viewModel,
			onRefresh: {
				await self.viewModel.fetchSources(self._sources, refresh: true)
			}
		)
		.toolbar {
			NBToolbarButton(
				systemImage: "plus",
				style: .icon,
				placement: .topBarTrailing,
				isDisabled: _addingSourceLoading
			) {
				_isAddingPresenting = true
			}
		}
		.sheet(isPresented: $_isAddingPresenting) {
			SourcesAddView()
				.adaptiveSheetSizing()
		}
	}

	@ViewBuilder
	private var sourcesListView: some View {
		NBListAdaptable {
			sourceHealthSection
			if !_filteredSources.isEmpty {
				allRepositoriesSection
				updatesSection
				repositoriesSection
			} else {
				// Still offer the updates row when there are no repos but updates are known.
				updatesSection
			}
		}
		.searchable(text: $_searchText, placement: .platform())
		.overlay {
			emptyStateView
		}
		.toolbar {
			toolbarContent
		}
		.refreshable {
			await viewModel.fetchSources(_sources, refresh: true)
		}
		.sheet(isPresented: $_isAddingPresenting) {
			SourcesAddView()
				.adaptiveSheetSizing()
		}
		.alert(
			deleteDialogTitle,
			isPresented: $_showDeleteConfirmation
		) {
			Button("Delete", role: .destructive) {
				deleteSelectedSources()
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("This action cannot be undone.")
		}
	}

	@ViewBuilder
	private var sourceHealthSection: some View {
		let health = _health
		NBSection(.localized("Source Health"), secondary: "\(_sources.count)", systemName: "waveform.path.ecg") {
			HStack(spacing: 8) {
				healthPill(.localized("%lld healthy", arguments: health.healthy), color: .green)
				healthPill(.localized("%lld failed", arguments: health.failed), color: health.failed > 0 ? .red : .secondary)
				healthPill(.localized("%lld stale", arguments: health.stale + health.neverFetched), color: health.stale + health.neverFetched > 0 ? .orange : .secondary)
			}

			if health.failed > 0 || health.stale > 0 || health.neverFetched > 0 {
				Button {
					Task { await viewModel.fetchSources(_sources, refresh: true) }
				} label: {
					Label(.localized("Refresh All Sources"), systemImage: "arrow.clockwise")
				}
				.font(.subheadline.weight(.semibold))
			}

			if let latest = _sources.compactMap({
				SourcePreferences.lastFetch(for: $0.identifier ?? $0.sourceURL?.absoluteString ?? "")
			}).max() {
				Text(String.localized("Last refresh %@", arguments: latest.formatted(date: .abbreviated, time: .shortened)))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	private func healthPill(_ title: String, color: Color) -> some View {
		Text(title)
			.font(.caption2.weight(.semibold))
			.foregroundStyle(color)
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.background(color.opacity(0.13), in: Capsule())
	}

	private var deleteDialogTitle: String {
		let count = _selectedSources.count
		return "Delete \(count) \(count == 1 ? "repository" : "repositories")?"
	}

	@ViewBuilder
	private var allRepositoriesSection: some View {
		Section {
            Button {
                _activeIndividualSource = nil
                _shouldNavigateToAllRepos = true
            } label: {
                HStack {
                    allRepositoriesLabel
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
		}
		.disabled(_isEditMode)
	}

	/// One-tap listing of every pending app update, with "Update All".
	@ViewBuilder
	private var updatesSection: some View {
		Section {
			NavigationLink(destination: UpdatesView()) {
				HStack(spacing: 18) {
					Image(systemName: "arrow.triangle.2.circlepath")
						.appIconStyle(tint: .accentColor)
					NBTitleWithSubtitleView(
						title: .localized("Updates"),
						subtitle: .localized("See every app that has a newer version")
					)
					Spacer()
					if AppUpdateChecker.shared.updateCount > 0 {
						Text(verbatim: AppUpdateChecker.shared.updateCount.description)
							.font(.subheadline.weight(.semibold))
							.foregroundStyle(.white)
							.padding(.horizontal, 9)
							.padding(.vertical, 3)
							.background(Color.accentColor, in: Capsule())
					}
				}
			}
			.buttonStyle(.plain)
		}
		.disabled(_isEditMode)
	}

	@ViewBuilder
	private var allRepositoriesLabel: some View {
		let isRegular = horizontalSizeClass != .compact
		HStack(spacing: 18) {
			Image("Repositories").appIconStyle()
			NBTitleWithSubtitleView(
				title: .localized("All Repositories"),
				subtitle: .localized("See all apps from your sources")
			)
		}
		.padding(isRegular ? 12 : 0)
		.background(
			isRegular
			? RoundedRectangle(cornerRadius: 18, style: .continuous)
				.fill(Color(.quaternarySystemFill))
			: nil
		)
	}

	@ViewBuilder
	private var repositoriesSection: some View {
		let sectionTitle = _isEditMode ? "\(_selectedSources.count) selected" : "\(_filteredSources.count)"
		NBSection(
			.localized("Repositories"),
			secondary: sectionTitle
		) {
			ForEach(_filteredSources) { source in
				if _isEditMode {
					editModeRow(for: source)
				} else {
					normalModeRow(for: source)
				}
			}
		}
	}

	@ViewBuilder
	private func editModeRow(for source: AltSource) -> some View {
		HStack(spacing: 12) {
			selectionButton(for: source)
			SourcesCellView(source: source, isEditMode: true)
		}
		.contentShape(Rectangle())
		.onTapGesture {
			toggleSelection(for: source)
		}
	}

	@ViewBuilder
	private func selectionButton(for source: AltSource) -> some View {
		let isPremium = source.sourceURL.map { VexSignAPI.isPremiumSource($0) } ?? false
		Button {
			toggleSelection(for: source)
		} label: {
			let isSelected = _selectedSources.contains(source)
			if isPremium {
				Image(systemName: "lock.fill")
					.font(.title3)
					.foregroundColor(.secondary.opacity(0.5))
			} else {
				Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
					.font(.title3)
					.foregroundColor(isSelected ? .accentColor : .secondary)
			}
		}
		.buttonStyle(.plain)
		.disabled(isPremium)
	}

	@ViewBuilder
	private func normalModeRow(for source: AltSource) -> some View {
        Button {
            _shouldNavigateToAllRepos = false
            _activeIndividualSource = source
        } label: {
            HStack {
                SourcesCellView(source: source, isEditMode: false)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
	}

	@ViewBuilder
	private var emptyStateView: some View {
		if _filteredSources.isEmpty {
			NBContentUnavailable(
				.localized("No Repositories"),
				systemImage: "globe.desk.fill",
				description: .localized("Get started by adding your first repository.")
			) {
				Button {
					_isAddingPresenting = true
				} label: {
					NBButton(.localized("Add Source"), style: .text)
				}
			}
		}
	}

	@ToolbarContentBuilder
	private var toolbarContent: some ToolbarContent {
		ToolbarItem(placement: .topBarLeading) {
			if _isEditMode {
				HStack(spacing: 12) {
					Button("Done") {
						withAnimation {
							_isEditMode = false
							_selectedSources.removeAll()
						}
					}
					Button(action: selectAllSources) {
						Text("Select All")
					}
				}
			} else {
				if !_filteredSources.isEmpty {
					Button("Edit") {
						withAnimation {
							_isEditMode = true
						}
					}
				}
			}
		}

		ToolbarItem(placement: .topBarTrailing) {
			if _isEditMode {
				Button(role: .destructive) {
					if !_selectedSources.isEmpty {
						_showDeleteConfirmation = true
					}
				} label: {
					Image(systemName: "trash")
				}
				.disabled(_selectedSources.isEmpty)
			} else {
				HStack(spacing: 14) {
					NavigationLink {
						SourcePriorityView(sources: Array(_sources))
					} label: {
						Image(systemName: "list.number")
					}
					.accessibilityLabel(Text(.localized("Repository Priority")))

					Button {
						_isAddingPresenting = true
					} label: {
						Image(systemName: "plus")
					}
					.disabled(_addingSourceLoading)
				}
			}
		}
	}

	// MARK: - Selection Methods
	private var _deletableSources: [AltSource] {
		_filteredSources.filter { source in
			guard let url = source.sourceURL else { return true }
			return !VexSignAPI.isPremiumSource(url)
		}
	}

	private func toggleSelection(for source: AltSource) {
		// Don't allow selecting premium sources
		if let url = source.sourceURL, VexSignAPI.isPremiumSource(url) { return }
		if _selectedSources.contains(source) {
			_selectedSources.remove(source)
		} else {
			_selectedSources.insert(source)
		}
	}

	private var areAllSourcesSelected: Bool {
		let all = Set(_deletableSources)
		return !all.isEmpty && _selectedSources == all
	}

	private func selectAllSources() {
		if areAllSourcesSelected {
			_selectedSources.removeAll()
		} else {
			_selectedSources = Set(_deletableSources)
		}
	}

	private func deleteSelectedSources() {
		withAnimation {
			for source in _selectedSources {
				// Skip premium sources — they can only be removed via Reset Premium
				if let url = source.sourceURL, VexSignAPI.isPremiumSource(url) {
					continue
				}
				Storage.shared.deleteSource(for: source)
			}
			_selectedSources.removeAll()
			_isEditMode = false
		}
	}

	// MARK: - Navigation Handler
	private func handlePendingNavigation(_ pendingNavigation: AppNavigationManager.PendingAppNavigation?) {
		guard let navigation = pendingNavigation else { return }

		if let activeSource = _activeIndividualSource {
			if let repository = viewModel.sources[activeSource],
			   appExistsInRepository(appId: navigation.appId, repository: repository) {
				// Already in the right source — let it handle scrolling.
				return
			} else {
				_activeIndividualSource = nil

				// Let the source close before opening All Repositories.
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					self._shouldNavigateToAllRepos = true
				}
				return
			}
		}

		if !_shouldNavigateToAllRepos {
			_shouldNavigateToAllRepos = true
		}
	}

	private func appExistsInRepository(appId: String, repository: ASRepository) -> Bool {
		for app in repository.apps {
			if app.currentUniqueId == appId {
				return true
			}
		}
		return false
	}
}
