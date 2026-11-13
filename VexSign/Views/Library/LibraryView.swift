//
//  LibraryView.swift
//  VexSign
//
//  Created by VexSign Contributors on 10.04.2025.
//

import SwiftUI
import CoreData
import NimbleViews
import NimbleExtensions

// MARK: - View
struct LibraryView: View {
    /// False when embedded in a workspace or pushed from another navigation stack.
    var ownsNavigationStack: Bool = true
    var workspaceSection: LibraryWorkspaceSection? = nil
    @StateObject var downloadManager = DownloadManager.shared
    @ObservedObject var tabSelection = TabSelectionObserver.shared
    @ObservedObject var updateChecker = AppUpdateChecker.shared
    @ObservedObject var lockManager = AppLockManager.shared
    @ObservedObject private var libraryStatus = LibraryStatusStore.shared
    @AppStorage("VexSign.library.layout") private var libraryLayout = "list"

    @State private var _selectedInfoAppPresenting: AnyApp?
    @State private var _selectedSigningAppPresenting: AnyApp?
    @State private var _isDownloadingPresenting = false
    @State private var _alertDownloadString: String = "" // for _isDownloadingPresenting
    @State private var _isExplorerPresenting = false
    @State private var _isDirectInstallPresenting = false
    @State private var _isGitHubImportPresenting = false

    // MARK: Selection State
    @State var _selectedAppUUIDs: Set<String> = []
    @State var _editMode: EditMode = .inactive
    @State var _showDeleteConfirmation = false
    @State var _batchRequest: BatchRequest?

    @State private var _searchText = ""
    @State private var _selectedScope: Scope = .all
    @AppStorage(LibraryDisplayPreferences.sortKey) private var _sortRaw: String = LibrarySort.manual.rawValue
    @AppStorage(LibraryDisplayPreferences.ascendingKey) private var _sortAscending: Bool = true

    @State private var _sizeSnapshot: [String: Int64] = [:]
    @State private var _sizeGeneration = UUID()

    @State private var scrollProxy: ScrollViewProxy?

    @Namespace private var _namespace

    // MARK: Fetch
    @FetchRequest(
        entity: Signed.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \Signed.sortIndex, ascending: true)],
        animation: .snappy
    ) private var _signedApps: FetchedResults<Signed>

    @FetchRequest(
        entity: Imported.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \Imported.sortIndex, ascending: true)],
        animation: .snappy
    ) private var _importedApps: FetchedResults<Imported>

    // MARK: Computed Properties
    private var _sort: LibrarySort { LibrarySort(rawValue: _sortRaw) ?? .manual }

    var hiddenAppsCount: Int {
        let sCount = _signedApps.filter { if let u = $0.uuid { return lockManager.isAppHidden(u) } else { return false } }.count
        let iCount = _importedApps.filter { if let u = $0.uuid { return lockManager.isAppHidden(u) } else { return false } }.count
        return (workspaceSection?.includesApp(isSigned: true) == false ? 0 : sCount) + (workspaceSection?.includesApp(isSigned: false) == false ? 0 : iCount)
    }

    var filteredSignedApps: [Signed] {
        let filtered = _signedApps.filter { app in
            guard workspaceSection?.includesApp(isSigned: true) != false else { return false }
            if !lockManager.isRevealingHiddenApps, let uuid = app.uuid, lockManager.isAppHidden(uuid) {
                return false
            }
            if _selectedScope == .attention && !needsAttention(app) { return false }
            return _searchText.isEmpty ||
            (app.name?.localizedCaseInsensitiveContains(_searchText) ?? false)
        }
        return _sorted(filtered)
    }

    var filteredImportedApps: [Imported] {
        let filtered = _importedApps.filter { app in
            guard workspaceSection?.includesApp(isSigned: false) != false else { return false }
            if !lockManager.isRevealingHiddenApps, let uuid = app.uuid, lockManager.isAppHidden(uuid) {
                return false
            }
            if _selectedScope == .attention && !needsAttention(app) { return false }
            return _searchText.isEmpty ||
            (app.name?.localizedCaseInsensitiveContains(_searchText) ?? false)
        }
        return _sorted(filtered)
    }

    private func _sorted<T: AppInfoPresentable>(_ apps: [T]) -> [T] {
        switch _sort {
        case .manual: return apps
        case .name:
            return apps.sorted { lhs, rhs in
                let cmp = (lhs.name ?? "").localizedCaseInsensitiveCompare(rhs.name ?? "")
                return _sortAscending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        case .date:
            return apps.sorted { lhs, rhs in
                let l = lhs.date ?? .distantPast
                let r = rhs.date ?? .distantPast
                return _sortAscending ? l < r : l > r
            }
        case .size:
            return apps.sorted { lhs, rhs in
                let l = _sizeSnapshot[lhs.uuid ?? ""] ?? 0
                let r = _sizeSnapshot[rhs.uuid ?? ""] ?? 0
                if l == r { return (lhs.uuid ?? "") < (rhs.uuid ?? "") }
                return _sortAscending ? l < r : l > r
            }
        }
    }

    /// Date/identity changes invalidate measurements; search/layout changes do not rescan disk.
    private var sizeMeasurementKey: LibrarySizeMeasurementKey {
        guard _sort == .size else { return .disabled }
        return LibrarySizeMeasurementKey.make(
            generation: _sizeGeneration,
            signed: _signedApps.map { (uuid: $0.uuid, date: $0.date) },
            imported: _importedApps.map { (uuid: $0.uuid, date: $0.date) }
        )
    }

    @MainActor
    private func measureLibrarySizes() async {
        guard _sort == .size else { return }
        let apps: [AppInfoPresentable] = Array(_signedApps).map { $0 as AppInfoPresentable }
            + Array(_importedApps).map { $0 as AppInfoPresentable }
        let entries = apps.compactMap { app -> LibrarySizeSnapshot.Entry? in
            guard let id = app.uuid, let directory = Storage.shared.getUuidDirectory(for: app) else { return nil }
            return LibrarySizeSnapshot.Entry(id: id, directory: directory)
        }
        do {
            let measured = try await LibrarySizeSnapshot.measure(entries)
            try Task.checkCancellation()
            _sizeSnapshot = measured
        } catch {
            // A superseded view snapshot must not replace newer measurements.
        }
    }

    var shouldShowSignedSection: Bool {
        workspaceSection?.includesApp(isSigned: true) != false && (_selectedScope == .all || _selectedScope == .attention || _selectedScope == .signed)
    }

    var shouldShowImportedSection: Bool {
        workspaceSection?.includesApp(isSigned: false) != false && (_selectedScope == .all || _selectedScope == .attention || _selectedScope == .imported)
    }

    private var hasNoContent: Bool {
        (!shouldShowSignedSection || filteredSignedApps.isEmpty) && (!shouldShowImportedSection || filteredImportedApps.isEmpty)
    }

    private func needsAttention(_ app: AppInfoPresentable) -> Bool {
        let status = libraryStatus.status(for: app)
        let certificate = Storage.shared.getCertificate(from: app)
        return LibraryAttentionReason.evaluate(
            isSigned: app.isSigned,
            expiry: status.expiresAt ?? certificate?.expiration,
            revoked: certificate?.revoked == true,
            hasUpdate: updateChecker.hasUpdate(for: app) != nil
        ) != nil
    }

    // MARK: Body
    var body: some View {
        NBNavigationView(.localized("Library"), ownsNavigationStack: ownsNavigationStack) {
            mainContent
                .task(id: sizeMeasurementKey) { await measureLibrarySizes() }
                .onReceive(NotificationCenter.default.publisher(for: LibrarySizeSnapshot.filesChanged)) { _ in
                    _sizeGeneration = UUID()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSManagedObjectContext.didSaveObjectsNotification)) { _ in
                    _sizeGeneration = UUID()
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if _editMode.isEditing {
                            HStack(spacing: 12) {
                                Button("Done") {
                                    withAnimation {
                                        _editMode = .inactive
                                        _selectedAppUUIDs.removeAll()
                                    }
                                }
                                .keyboardShortcut(.cancelAction)
                                Button(action: selectAllApps) {
                                    Text("Select All")
                                }
                                .keyboardShortcut("a", modifiers: .command)
                            }
                        } else {
                            Button("Edit") {
                                withAnimation {
                                    _editMode = .active
                                }
                            }
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        if !_editMode.isEditing {
                            Menu {
                                Picker(.localized("Library layout"), selection: $libraryLayout) {
                                    Label(.localized("Compact list"), systemImage: "list.bullet").tag("list")
                                    Label(.localized("Adaptive cards"), systemImage: "rectangle.grid.1x2").tag("grid")
                                    Label(.localized("Icon grid"), systemImage: "square.grid.2x2").tag("icons")
                                }
                                Section(.localized("Sort")) {
                                    ForEach(LibrarySort.allCases, id: \.rawValue) { option in
                                        Button {
                                            if _sortRaw == option.rawValue {
                                                _sortAscending.toggle()
                                            } else {
                                                _sortRaw = option.rawValue
                                            }
                                        } label: {
                                            HStack {
                                                Text(option.title)
                                                if _sortRaw == option.rawValue {
                                                    Image(systemName: _sortAscending ? "chevron.up" : "chevron.down")
                                                }
                                            }
                                        }
                                    }
                                }
                                Divider()
                                importMenuActions
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if _editMode.isEditing {
                        selectionActionBar
                    }
                }
                .environment(\.editMode, $_editMode)
                .sheet(item: $_selectedInfoAppPresenting) { app in
                    LibraryInfoView(app: app.base)
                }
                .sheet(isPresented: $_isExplorerPresenting) {
                    IPAExplorerHomeView()
                }
                .sheet(isPresented: $_isGitHubImportPresenting) {
                    GitHubIPAImportView()
                }
                .sheet(isPresented: $_isDirectInstallPresenting) {
                    DirectInstallSheet()
                }
                .fullScreenCover(item: $_batchRequest, onDismiss: InstallCleanup.flush) { request in
                    BatchSignView(apps: request.apps, mode: request.mode)
                }
                .fullScreenCover(item: $_selectedSigningAppPresenting) { app in
                    SigningView(app: app.base, installAfterSigning: app.installAfterSigning)
                        .compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
                }
                .alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {
                    urlImportAlert
                }
                .nbOnChange(of: _editMode) { mode in
                    if mode == .inactive {
                        _selectedAppUUIDs.removeAll()
                    } else {
                        UIApplication.shared.endEditing()
                    }
                }
                .alert(
                    deleteDialogTitle,
                    isPresented: $_showDeleteConfirmation
                ) {
                    Button("Delete", role: .destructive) {
                        bulkDeleteSelectedApps()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This action cannot be undone.")
                }
                .onAppear { presentPendingExplorer() }
                .onChange(of: tabSelection.ipaExplorerRequested) { _, _ in presentPendingExplorer() }
                .onReceive(NotificationCenter.default.publisher(for: .openIPAExplorer)) { _ in
                    Presentation.afterDismiss { _isExplorerPresenting = true }
                }
        }
    }

    private func presentPendingExplorer() {
        guard tabSelection.ipaExplorerRequested else { return }
        tabSelection.ipaExplorerRequested = false
        Presentation.afterDismiss { _isExplorerPresenting = true }
    }

    private var deleteDialogTitle: String {
        let count = _selectedAppUUIDs.count
        return "Delete \(count) \(count == 1 ? "app" : "apps")?"
    }

    // MARK: Main Content View
    @ViewBuilder
    private var mainContent: some View {
        ScrollViewReader { proxy in
            NBListAdaptable(
                layout: libraryLayout != "list" && !_editMode.isEditing ? .grid : .list,
                minimumCardWidth: libraryLayout == "icons" ? 160 : 340
            ) {
                if !hasNoContent {
                    appsListContent
                }
            }
            .searchable(text: $_searchText, placement: .platform())
            .onReceive(TabSelectionObserver.shared.$searchRequest) { request in
                guard let request, request.tab == .library else { return }
                _searchText = request.query
                _selectedScope = .all
                TabSelectionObserver.shared.searchRequest = nil
            }
            .compatSearchScopes($_selectedScope) {
                ForEach(workspaceSection == nil ? Scope.allCases : [.all, .attention], id: \.displayName) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollProxy = proxy
            }
            .task {
                LibraryStatusStore.shared.refresh(
                    _signedApps.map { $0 as AppInfoPresentable } + _importedApps.map { $0 as AppInfoPresentable }
                )

                if AppStoreUpdateTracker.isEnabled {
                    let apps: [AppInfoPresentable] = _signedApps.map { $0 as AppInfoPresentable }
                        + _importedApps.map { $0 as AppInfoPresentable }
                    await AppStoreUpdateTracker.shared.refresh(apps: apps)
                }
                if updateChecker.availableUpdates.isEmpty {
                    await updateChecker.checkNow()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                libraryStatus.refresh(
                    _signedApps.map { $0 as AppInfoPresentable } + _importedApps.map { $0 as AppInfoPresentable },
                    force: true
                )
            }
            .refreshable {
                libraryStatus.refresh(
                    _signedApps.map { $0 as AppInfoPresentable } + _importedApps.map { $0 as AppInfoPresentable },
                    force: true
                )
            }
            .nbOnChange(of: tabSelection.highlightedAppUUID) { newUUID in
                if let uuid = newUUID {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        proxy.scrollTo(uuid, anchor: .center)
                    }
                }
            }
        }
        .overlay {
            if hasNoContent {
                emptyStateView
            }
        }
    }

    // MARK: Apps List Content
    @ViewBuilder
    private var appsListContent: some View {
        if workspaceSection == nil, updateChecker.updateCount > 0, !_editMode.isEditing {
            updatesAvailableSection
        }

        if !filteredSignedApps.isEmpty, shouldShowSignedSection {
            signedAppsSection
        }

        if !filteredImportedApps.isEmpty, shouldShowImportedSection {
            importedAppsSection
        }

        if hiddenAppsCount > 0, !_editMode.isEditing {
            hiddenAppsVaultSection
        }
    }

    // MARK: Signed Apps Section
    @ViewBuilder
    private var signedAppsSection: some View {
        let selectedSignedCount = filteredSignedApps.filter { app in
            guard let uuid = app.uuid else { return false }
            return _selectedAppUUIDs.contains(uuid)
        }.count

        let sectionTitle = _editMode.isEditing && selectedSignedCount > 0
            ? "\(selectedSignedCount) selected"
            : filteredSignedApps.count.description

        NBSection(
            .localized("Signed"),
            secondary: sectionTitle
        ) {
            ForEach(filteredSignedApps, id: \.uuid) { app in
                LibraryCellView(
                    app: app,
                    selectedInfoAppPresenting: $_selectedInfoAppPresenting,
                    selectedSigningAppPresenting: $_selectedSigningAppPresenting,
                    selectedAppUUIDs: $_selectedAppUUIDs,
                    isHighlighted: app.uuid == tabSelection.highlightedAppUUID,
                    onSelectMore: { _beginSelection(with: app) },
                    isIconTile: libraryLayout == "icons" && !_editMode.isEditing,
                    isGridLayout: libraryLayout != "list" && !_editMode.isEditing
                )
                .compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
                .id(app.uuid)
            }
            .onMove(perform: (_searchText.isEmpty && _sort == .manual) ? _moveSignedApps : nil)
        }
    }

    // MARK: Imported Apps Section
    @ViewBuilder
    private var importedAppsSection: some View {
        let selectedImportedCount = filteredImportedApps.filter { app in
            guard let uuid = app.uuid else { return false }
            return _selectedAppUUIDs.contains(uuid)
        }.count

        let sectionTitle = _editMode.isEditing && selectedImportedCount > 0
            ? "\(selectedImportedCount) selected"
            : filteredImportedApps.count.description

        NBSection(
            .localized("Imported"),
            secondary: sectionTitle
        ) {
            ForEach(filteredImportedApps, id: \.uuid) { app in
                LibraryCellView(
                    app: app,
                    selectedInfoAppPresenting: $_selectedInfoAppPresenting,
                    selectedSigningAppPresenting: $_selectedSigningAppPresenting,
                    selectedAppUUIDs: $_selectedAppUUIDs,
                    isHighlighted: app.uuid == tabSelection.highlightedAppUUID,
                    onSelectMore: { _beginSelection(with: app) },
                    isIconTile: libraryLayout == "icons" && !_editMode.isEditing,
                    isGridLayout: libraryLayout != "list" && !_editMode.isEditing
                )
                .compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
                .id(app.uuid)
            }
            .onMove(perform: (_searchText.isEmpty && _sort == .manual) ? _moveImportedApps : nil)
        }
    }

    // MARK: Empty State View
    @ViewBuilder
    private var emptyStateView: some View {
        let isFiltered = !_searchText.isEmpty || _selectedScope != .all
        NBContentUnavailable(
            isFiltered ? .localized("No matching apps") : .localized("No Apps"),
            systemImage: isFiltered ? "line.3.horizontal.decrease.circle" : "square.and.arrow.down",
            description: isFiltered
                ? .localized("No visible library apps match this search and filter. Unknown status is not treated as a failure.")
                : .localized("Import an IPA to customize and sign it. Your original file stays separate from the library copy.")
        ) {
            if isFiltered {
                Button(.localized("Clear filters")) { _searchText = ""; _selectedScope = .all }
            } else {
                Menu { importMenuActions } label: {
                    NBButton(.localized("Import IPA"), style: .text)
                }
            }
        }
    }

    // MARK: Import Menu Actions
    @ViewBuilder
    private var importMenuActions: some View {
        Button(.localized("Import from Files"), systemImage: "folder") {
            DocumentPicker.open([.ipa, .tipa], multiple: true, folder: .apps) { urls in
                if !urls.isEmpty { tabSelection.librarySection = .apps }
                for url in urls {
                    _ = downloadManager.startArchive(from: url, id: "VexSignManualDownload_\(UUID().uuidString)", reviewDuplicates: true)
                }
            }
        }
        Button(.localized("Import from URL"), systemImage: "globe") {
            Presentation.afterDismiss { _isDownloadingPresenting = true }
        }
        Button(.localized("Import from GitHub"), systemImage: "shippingbox") {
            Presentation.afterDismiss { _isGitHubImportPresenting = true }
        }
        Button(.localized("Direct Install from URL"), systemImage: "arrow.down.app") {
            Presentation.afterDismiss { _isDirectInstallPresenting = true }
        }
        Button(.localized("Open in IPA Explorer"), systemImage: "doc.text.magnifyingglass") {
            Presentation.afterDismiss { _isExplorerPresenting = true }
        }
    }

    // MARK: URL Import Alert
    @ViewBuilder
    private var urlImportAlert: some View {
        TextField(.localized("URL"), text: $_alertDownloadString)
            .textInputAutocapitalization(.never)
        Button(.localized("Cancel"), role: .cancel) {
            _alertDownloadString = ""
        }
        Button(.localized("OK")) {
            if let url = URL(string: _alertDownloadString) {
                tabSelection.librarySection = .apps
                _ = downloadManager.startDownload(
                    from: url,
                    id: "VexSignManualDownload_\(UUID().uuidString)"
                )
            }
        }
    }
}

// MARK: - Extension: View (Sort)
extension LibraryView {
    enum Scope: CaseIterable {
        case all
        case signed
        case imported
        case attention

        var displayName: String {
            switch self {
            case .all: return .localized("All")
            case .signed: return .localized("Signed")
            case .imported: return .localized("Imported")
            case .attention: return .localized("Needs Attention")
            }
        }
    }
}
