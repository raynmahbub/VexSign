//
//  ContentView.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 10.04.2025.
//

import SwiftUI
import CoreData
import NimbleViews
import NimbleExtensions

// MARK: - View
struct LibraryView: View {
    @StateObject var downloadManager = DownloadManager.shared
    @ObservedObject private var tabSelection = TabSelectionObserver.shared
    @ObservedObject private var updateChecker = AppUpdateChecker.shared
    @ObservedObject private var lockManager = AppLockManager.shared
    @ObservedObject private var libraryStatus = LibraryStatusStore.shared
    @AppStorage("VexSign.library.layout") private var libraryLayout = "list"
    
    @State private var _selectedInfoAppPresenting: AnyApp?
    @State private var _selectedSigningAppPresenting: AnyApp?
    @State private var _isDownloadingPresenting = false
    @State private var _alertDownloadString: String = "" // for _isDownloadingPresenting
    @State private var _isExplorerPresenting = false
    @State private var _isDirectInstallPresenting = false
    
    // MARK: Selection State
    @State private var _selectedAppUUIDs: Set<String> = []
    @State private var _editMode: EditMode = .inactive
    @State private var _showDeleteConfirmation = false
    @State private var _batchRequest: BatchRequest?

    @State private var _searchText = ""
    @State private var _selectedScope: Scope = .all
    @AppStorage(LibraryDisplayPreferences.sortKey) private var _sortRaw: String = LibrarySort.manual.rawValue
    @AppStorage(LibraryDisplayPreferences.ascendingKey) private var _sortAscending: Bool = true

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

    private var hiddenAppsCount: Int {
        let sCount = _signedApps.filter { if let u = $0.uuid { return lockManager.isAppHidden(u) } else { return false } }.count
        let iCount = _importedApps.filter { if let u = $0.uuid { return lockManager.isAppHidden(u) } else { return false } }.count
        return sCount + iCount
    }

    private var filteredSignedApps: [Signed] {
        let filtered = _signedApps.filter { app in
            if !lockManager.isRevealingHiddenApps, let uuid = app.uuid, lockManager.isAppHidden(uuid) {
                return false
            }
            if _selectedScope == .attention && !needsAttention(app) { return false }
            return _searchText.isEmpty ||
            (app.name?.localizedCaseInsensitiveContains(_searchText) ?? false)
        }
        return _sorted(filtered)
    }
    
    private var filteredImportedApps: [Imported] {
        let filtered = _importedApps.filter { app in
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
                let l = Storage.shared.getUuidDirectory(for: lhs).map { FileManager.default.allocatedSize(at: $0) } ?? 0
                let r = Storage.shared.getUuidDirectory(for: rhs).map { FileManager.default.allocatedSize(at: $0) } ?? 0
                return _sortAscending ? l < r : l > r
            }
        }
    }
    
    private var shouldShowSignedSection: Bool {
        _selectedScope == .all || _selectedScope == .attention || _selectedScope == .signed
    }
    
    private var shouldShowImportedSection: Bool {
        _selectedScope == .all || _selectedScope == .attention || _selectedScope == .imported
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
        NBNavigationView(.localized("Library")) {
            mainContent
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
                .sheet(isPresented: $_isDirectInstallPresenting) {
                    DirectInstallSheet()
                }
                .fullScreenCover(item: $_batchRequest, onDismiss: InstallCleanup.flush) { request in
                    BatchSignView(apps: request.apps, mode: request.mode)
                }
                .fullScreenCover(item: $_selectedSigningAppPresenting) { app in
                    SigningView(app: app.base)
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
                .onReceive(NotificationCenter.default.publisher(for: .openIPAExplorer)) { _ in
                    Presentation.afterDismiss { _isExplorerPresenting = true }
                }
        }
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
            .compatSearchScopes($_selectedScope) {
                ForEach(Scope.allCases, id: \.displayName) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollProxy = proxy
            }
            .task {
                // One batched read of what the device has and what each stored bundle carries
                // Rows also request their own on appear, throttled, so a recycled cell
                // never blocks the list on a probe.
                LibraryStatusStore.shared.refresh(
                    _signedApps.map { $0 as AppInfoPresentable } + _importedApps.map { $0 as AppInfoPresentable }
                )

                // Opt-in (Settings → Updates): badge apps whose App Store release
                // is newer than the installed copy. Lookups are cached per session.
                if AppStoreUpdateTracker.isEnabled {
                    let apps: [AppInfoPresentable] = _signedApps.map { $0 as AppInfoPresentable }
                        + _importedApps.map { $0 as AppInfoPresentable }
                    await AppStoreUpdateTracker.shared.refresh(apps: apps)
                }
                if updateChecker.availableUpdates.isEmpty {
                    await updateChecker.checkNow()
                }
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
        if updateChecker.updateCount > 0, !_editMode.isEditing {
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

    // MARK: - Hidden Apps Vault Section (LiveContainer)
    private var hiddenAppsVaultSection: some View {
        NBSection(.localized("Hidden Apps")) {
            Button {
                NBHaptic.tap(.medium)
                lockManager.authenticateToRevealHidden { _ in }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill((lockManager.isRevealingHiddenApps ? Color.purple : Color.secondary).opacity(0.15))
                            .frame(width: 32, height: 32)
                        Image(systemName: lockManager.isRevealingHiddenApps ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(lockManager.isRevealingHiddenApps ? Color.purple : Color.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(lockManager.isRevealingHiddenApps ? .localized("Hidden Apps Revealed") : .localized("Hidden Apps Vault"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.primary)
                        Text(lockManager.isRevealingHiddenApps ? .localized("Tap to conceal hidden applications") : String.localized("%lld hidden app(s) • Tap to unlock", arguments: hiddenAppsCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: lockManager.isRevealingHiddenApps ? "lock.open.fill" : "lock.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(lockManager.isRevealingHiddenApps ? Color.purple : Color.secondary)
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Updates Available Section (Apps & Quantity)
    private var updatesAvailableSection: some View {
        NBSection(
            .localized("Updates Available"),
            secondary: "\(updateChecker.updateCount) " + (updateChecker.updateCount == 1 ? .localized("Update") : .localized("Updates"))
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.userTint.opacity(0.14))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.userTint)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateChecker.updateCount == 1 ? .localized("1 App Update Available") : String.localized("%lld App Updates Available", arguments: updateChecker.updateCount))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("New versions ready from your repositories"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    NavigationLink(destination: UpdatesView()) {
                        Text(.localized("View All"))
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.userTint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)

                Divider().opacity(0.5)

                // Preview apps with available updates
                ForEach(updateChecker.availableUpdates.prefix(3)) { item in
                    HStack(spacing: 10) {
                        AsyncImage(url: item.iconURL) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFit()
                            } else {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.userTint.opacity(0.12))
                                    .overlay(
                                        Image(systemName: "app.fill")
                                            .font(.caption)
                                            .foregroundStyle(Color.userTint)
                                    )
                            }
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(item.installedVersion ?? "1.0")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                Text(item.sourceVersion ?? "1.1")
                                    .foregroundStyle(Color.userTint)
                                    .fontWeight(.semibold)
                                Text("• \(item.sourceName)")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .font(.caption2)
                        }

                        Spacer()

                        if let url = item.downloadURL {
                            Button {
                                _ = downloadManager.startDownload(
                                    from: url,
                                    id: item.app.currentUniqueId,
                                    appName: item.displayName,
                                    appDescription: item.app.localizedDescription
                                )
                                Toast.info(.localized("Download started"), systemImage: "arrow.down.circle")
                            } label: {
                                Text(.localized("UPDATE"))
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.userTint.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.userTint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if updateChecker.availableUpdates.count > 3 {
                    NavigationLink(destination: UpdatesView()) {
                        HStack {
                            Spacer()
                            Text(String.localized("+%lld more pending updates", arguments: updateChecker.availableUpdates.count - 3))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.userTint)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.userTint)
                            Spacer()
                        }
                        .padding(.top, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
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
                    isIconTile: libraryLayout == "icons" && !_editMode.isEditing
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
                    isIconTile: libraryLayout == "icons" && !_editMode.isEditing
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
    
    // MARK: Selection Action Bar
    private var selectionActionBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(String.localized("%lld selected", arguments: _selectedAppUUIDs.count))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            WorkspaceActionGroup { selectionActionButtons }
        }
        .padding(.horizontal)
        .padding(.vertical, Theme.Spacing.medium)
        .background(Theme.card)
        .overlay(alignment: .top) { Divider() }
        .reportsBottomBarHeight()
    }

    @ViewBuilder
    private var selectionActionButtons: some View {
        let selection = selectedApps()
        let canSign = selection.contains { !$0.isSigned }
        let canInstall = !selection.isEmpty && selection.allSatisfy { $0.isSigned }
        if canInstall {
            _actionButton(.localized("Install"), systemImage: "square.and.arrow.down") { _startBatch(.install) }
        } else {
            _actionButton(.localized("Sign"), systemImage: "signature", isDisabled: !canSign) { _startBatch(.sign) }
        }
        _actionButton(.localized("Export"), systemImage: "square.and.arrow.up") {
            let apps = selectedApps()
            _selectedAppUUIDs.removeAll()
            _editMode = .inactive
            for app in apps { InstallQueue.shared.enqueue(app, exporting: true) }
        }
        Menu {
            if !canInstall {
                Button(.localized("Sign & Install"), systemImage: "square.and.arrow.down.on.square") {
                    _startBatch(.signAndInstall)
                }
                .disabled(!canSign || selection.isEmpty)
            }
            Button(.localized("Delete selected apps"), systemImage: "trash", role: .destructive) {
                _showDeleteConfirmation = true
            }
        } label: {
            Label(.localized("More"), systemImage: "ellipsis.circle")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(selection.isEmpty)
        .accessibilityLabel(Text(.localized("More actions for selected apps")))
    }

    @ViewBuilder
    private func _actionButton(
        _ title: String,
        systemImage: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isDisabled || _selectedAppUUIDs.isEmpty)
    }

    // MARK: Import Menu Actions
    @ViewBuilder
    private var importMenuActions: some View {
        Button(.localized("Import from Files"), systemImage: "folder") {
            DocumentPicker.open([.ipa, .tipa], multiple: true, folder: .apps) { urls in
                for url in urls {
                    _ = downloadManager.startArchive(from: url, id: "VexSignManualDownload_\(UUID().uuidString)", reviewDuplicates: true)
                }
            }
        }
        Button(.localized("Import from URL"), systemImage: "globe") {
            Presentation.afterDismiss { _isDownloadingPresenting = true }
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
                _ = downloadManager.startDownload(
                    from: url,
                    id: "VexSignManualDownload_\(UUID().uuidString)"
                )
            }
        }
    }
}

// MARK: - Extension: Batch
extension LibraryView {
    struct BatchRequest: Identifiable {
        let id = UUID()
        let apps: [AppInfoPresentable]
        let mode: BatchJobRunner.Mode
    }

    private func selectedApps() -> [AppInfoPresentable] {
        getAllApps().filter { app in
            guard let uuid = app.uuid else { return false }
            return _selectedAppUUIDs.contains(uuid)
        }
    }

    private func _beginSelection(with app: AppInfoPresentable) {
        guard let uuid = app.uuid else { return }

        withAnimation {
            _editMode = .active
            _selectedAppUUIDs = [uuid]
        }
    }

    private func _startBatch(_ mode: BatchJobRunner.Mode) {
        let apps = selectedApps()
        guard !apps.isEmpty else { return }

        _batchRequest = BatchRequest(apps: apps, mode: mode)
        _selectedAppUUIDs.removeAll()
        _editMode = .inactive
    }
}

// MARK: - Extension: Reorder
extension LibraryView {
    private func _moveSignedApps(from source: IndexSet, to destination: Int) {
        var apps = filteredSignedApps
        apps.move(fromOffsets: source, toOffset: destination)

        for (index, app) in apps.enumerated() {
            app.sortIndex = Int32(index)
        }
        Storage.shared.saveContext()
    }

    private func _moveImportedApps(from source: IndexSet, to destination: Int) {
        var apps = filteredImportedApps
        apps.move(fromOffsets: source, toOffset: destination)

        for (index, app) in apps.enumerated() {
            app.sortIndex = Int32(index)
        }
        Storage.shared.saveContext()
    }
}

// MARK: - Extension: Bulk Delete
extension LibraryView {
    private func bulkDeleteSelectedApps() {
        for app in selectedApps() {
            Storage.shared.deleteApp(for: app)
        }

        _selectedAppUUIDs.removeAll()
        _editMode = .inactive
    }
    
    private func getAllApps() -> [AppInfoPresentable] {
        var allApps: [AppInfoPresentable] = []

        if shouldShowSignedSection {
            allApps.append(contentsOf: filteredSignedApps)
        }

        if shouldShowImportedSection {
            allApps.append(contentsOf: filteredImportedApps)
        }

        return allApps
    }

    private var areAllAppsSelected: Bool {
        let allApps = getAllApps()
        let allUUIDs = Set(allApps.compactMap { $0.uuid })
        return !allUUIDs.isEmpty && _selectedAppUUIDs == allUUIDs
    }

    private func selectAllApps() {
        if areAllAppsSelected {
            _selectedAppUUIDs.removeAll()
        } else {
            let allApps = getAllApps()
            _selectedAppUUIDs = Set(allApps.compactMap { $0.uuid })
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
