//
//  DownloadsTabView.swift
//  VexSign — Downloads Management View
//

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers
import NimbleExtensions

struct DownloadsTabView: View {
    var ownsNavigationStack: Bool = true
    @Environment(\.appContainer) private var appContainer
    @State private var viewModel: DownloadsTabViewModel?

    init(ownsNavigationStack: Bool = true, viewModel: DownloadsTabViewModel? = nil) {
        self.ownsNavigationStack = ownsNavigationStack
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if let viewModel {
                DownloadsTabContent(ownsNavigationStack: ownsNavigationStack, viewModel: viewModel)
            } else {
                ProgressView()
                    .onAppear {
                        let container = appContainer ?? AppContainer.live()
                        viewModel = container.makeDownloadsTabViewModel()
                    }
            }
        }
    }
}

private struct DownloadsTabContent: View {
    let ownsNavigationStack: Bool
    @ObservedObject var viewModel: DownloadsTabViewModel
    @ObservedObject var downloadManager = DownloadManager.shared
    @State private var filter: Filter = .all
    @State private var showAddSheet = false
    @State private var addURLText = ""
    @State private var showImportPicker = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", active = "Active", paused = "Paused", completed = "Completed"
        var id: String { rawValue }
    }

    private var activeCount: Int {
        downloadManager.downloads.filter { $0.isActive && !$0.isPaused && $0.phase != .completed }.count
    }

    private var pausedCount: Int {
        downloadManager.downloads.filter { $0.isPaused }.count
    }

    private var completedCount: Int {
        downloadManager.downloads.filter { $0.phase == .completed }.count + viewModel.downloadedFiles.count
    }

    private var filteredDownloads: [Download] {
        switch filter {
        case .all: return downloadManager.downloads
        case .active: return downloadManager.downloads.filter { $0.isActive && !$0.isPaused && $0.phase != .completed }
        case .paused: return downloadManager.downloads.filter { $0.isPaused }
        case .completed: return downloadManager.downloads.filter { $0.phase == .completed }
        }
    }

    var body: some View {
        Group {
            if ownsNavigationStack {
                NBNavigationView(.localized("Downloads"), displayMode: .large) {
                    listContent
                        .toolbar { toolbar }
                }
            } else {
                listContent
                    .navigationTitle(.localized("Downloads"))
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { toolbar }
            }
        }
        .sheet(isPresented: $showAddSheet) { addSheet }
        .sheet(isPresented: $showImportPicker) {
            FileImporterRepresentableView(
                allowedContentTypes: [.ipa, .tipa, .zip, .data],
                allowsMultipleSelection: true
            ) { urls in
                viewModel.importIntoStaging(urls)
            }
        }
        .onAppear { viewModel.refreshStagedFiles() }
        .onChange(of: downloadManager.downloads.count) { _ in viewModel.refreshStagedFiles() }
        .undoableRemovalBanner()
    }

    private var listContent: some View {
        List {
            header
            filterPills
            if !filteredDownloads.isEmpty { activeDownloadsSection }
            if (filter == .all || filter == .completed) && !viewModel.downloadedFiles.isEmpty {
                downloadedFilesSection
            }
            if filteredDownloads.isEmpty && ((filter != .all && filter != .completed) || viewModel.downloadedFiles.isEmpty) {
                emptyState
            }
            actionsSection
        }
        .listStyle(.insetGrouped)
        .refreshable {
            viewModel.refreshStagedFiles()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                TaskCenterView()
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .accessibilityLabel(Text(.localized("Task Center")))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(.localized("Download from URL…"), systemImage: "link") { showAddSheet = true }
                Button(.localized("Import from Files…"), systemImage: "square.and.arrow.down") { showImportPicker = true }
                if !downloadManager.downloads.isEmpty || !viewModel.downloadedFiles.isEmpty {
                    Divider()
                    Button(.localized("Pause All"), systemImage: "pause.fill") { downloadManager.pauseAllDownloads() }
                    Button(.localized("Resume All"), systemImage: "play.fill") { downloadManager.resumeAllDownloads() }
                    Divider()
                    Button(.localized("Clear Completed"), systemImage: "trash", role: .destructive) {
                        viewModel.clearCompleted(in: downloadManager)
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        ToolbarItem(placement: .topBarLeading) {
            if activeCount > 0 {
                Label("\(activeCount) active", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.userTint)
            }
        }
    }

    // MARK: - Header
    private var header: some View {
        Section {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.tintSoft).frame(width: 44, height: 44)
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.tint)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Downloads")).font(.headline)
                        Text(verbatim: downloadManager.downloads.isEmpty && viewModel.downloadedFiles.isEmpty ? String.localized("No downloads yet") : String.localized("%lld active • %lld completed", arguments: activeCount, completedCount))
                            .font(.caption).foregroundStyle(.secondary)
                        if downloadManager.currentDownloadSpeed > 0 {
                            Text(verbatim: downloadManager.currentDownloadSpeed.formattedByteCount + "/s")
                                .font(.caption2.weight(.medium)).foregroundStyle(Theme.tint).monospacedDigit()
                        }
                    }
                    Spacer()
                    let totalCount = downloadManager.downloads.count + viewModel.downloadedFiles.count
                    if totalCount > 0 {
                        VStack(spacing: 4) {
                            Text("\(totalCount)").font(.title3.bold()).monospacedDigit().foregroundStyle(.primary)
                            Text(.localized("items")).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.quaternary, in: Capsule())
                    }
                }
                if !downloadManager.downloads.isEmpty {
                    let summary = DownloadProgressSummary(downloadManager.downloads)
                    VStack(spacing: 6) {
                        DownloadPhaseBar(phase: summary.phase, progress: summary.progress)
                        HStack {
                            Text("\(Int(summary.progress * 100))%").font(.caption2.weight(.semibold)).foregroundStyle(summary.phase.tint).monospacedDigit()
                            Spacer()
                            Text(summary.phase.title).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .listRowBackground(Theme.card)
    }

    // MARK: - Filter Pills
    private var filterPills: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { f in
                        let selected = filter == f
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { filter = f }
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(color(for: f)).frame(width: 7, height: 7)
                                Text(.localized(f.rawValue)).font(.caption.weight(selected ? .semibold : .regular))
                                let count: Int = {
                                    switch f {
                                    case .all: return downloadManager.downloads.count + viewModel.downloadedFiles.count
                                    case .active: return activeCount
                                    case .paused: return pausedCount
                                    case .completed: return completedCount
                                    }
                                }()
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(selected ? .white.opacity(0.2) : Color.primary.opacity(0.08), in: Capsule())
                                        .monospacedDigit()
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(selected ? Color.userTint : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                            .foregroundStyle(selected ? .white : .primary)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.06), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        }
        .headerProminence(.increased)
    }

    private func color(for f: Filter) -> Color {
        switch f {
        case .all: return .secondary
        case .active: return .blue
        case .paused: return .orange
        case .completed: return .green
        }
    }

    // MARK: - Active Downloads
    private var activeDownloadsSection: some View {
        Section {
            ForEach(filteredDownloads, id: \.id) { dl in
                DownloadRow(download: dl, onOpenStaging: { viewModel.openInFiles(viewModel.stagingDirectoryURL) })
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if dl.canCancel {
                            Button(role: .destructive) { DownloadManager.shared.cancelDownload(dl) } label: { Label(.localized("Cancel"), systemImage: "xmark") }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if dl.canPause && dl.isPaused {
                            Button { DownloadManager.shared.resumeDownload(dl) } label: { Label(.localized("Resume"), systemImage: "play.fill") }.tint(.green)
                        } else if dl.canPause {
                            Button { DownloadManager.shared.pauseDownload(dl) } label: { Label(.localized("Pause"), systemImage: "pause.fill") }.tint(.orange)
                        }
                    }
            }
        } header: {
            Text(.localized("Active Downloads"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .headerProminence(.increased)
    }

    // MARK: - Downloaded / Finished IPAs
    private var downloadedFilesSection: some View {
        Section {
            ForEach(viewModel.downloadedFiles) { item in
                HStack(spacing: 12) {
                    Image(systemName: "doc.zipper")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(item.formattedSize)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(item.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("• " + .localized("Downloaded"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }

                    Spacer()

                    Menu {
                        Button {
                            viewModel.importToLibrary(item)
                        } label: {
                            Label(.localized("Import to Library"), systemImage: "square.grid.2x2.fill")
                        }

                        Button {
                            FileManagerActions.share(item.url)
                        } label: {
                            Label(.localized("Share"), systemImage: "square.and.arrow.up")
                        }

                        Button {
                            viewModel.openInFiles(item.url)
                        } label: {
                            Label(.localized("Open in Files"), systemImage: "folder")
                        }

                        Divider()

                        Button(role: .destructive) {
                            RecoverableFileRemoval.removeOfferingUndo(item.url) { viewModel.refreshStagedFiles() }
                        } label: {
                            Label(.localized("Delete"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        RecoverableFileRemoval.removeOfferingUndo(item.url) { viewModel.refreshStagedFiles() }
                    } label: {
                        Label(.localized("Delete"), systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        viewModel.importToLibrary(item)
                    } label: {
                        Label(.localized("Import"), systemImage: "square.grid.2x2.fill")
                    }
                    .tint(.blue)
                }
            }
        } header: {
            HStack {
                Text(.localized("Downloaded IPAs"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.downloadedFiles.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .headerProminence(.increased)
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: filter == .all ? "arrow.down.circle" : "tray")
                    .font(.system(size: 44)).foregroundStyle(.secondary).padding(.top, 8)
                Text(verbatim: filter == .all ? String.localized("No downloads") : String.localized("No %@ downloads", arguments: filter.rawValue.lowercased()))
                    .font(.headline)
                Text(.localized("Download apps from the App Store tab or paste a direct IPA link.")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                Button { showAddSheet = true } label: {
                    Label(.localized("Download from URL"), systemImage: "link").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(Color.userTint).padding(.top, 4)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }

    // MARK: - Actions
    private var actionsSection: some View {
        Section {
            NavigationLink(destination: FileManagerView(directory: viewModel.stagingDirectoryURL)) {
                Label(.localized("Downloads Folder"), systemImage: "folder")
            }
            // Single back navigation bar: inNavigationStack: false
            NavigationLink(destination: LogsHistoryView(inNavigationStack: false)) {
                Label(.localized("Activity Logs"), systemImage: "text.alignleft")
            }
            if !downloadManager.downloads.isEmpty || !viewModel.downloadedFiles.isEmpty {
                Button(.localized("Clear Completed"), systemImage: "trash", role: .destructive) {
                    viewModel.clearCompleted(in: downloadManager)
                }
            }
        } header: {
            Label(.localized("Manage"), systemImage: "gearshape").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        } footer: {
            Text(.localized("Active downloads continue in background. Swipe a row to cancel, or use the menu to pause all."))
        }
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField(.localized("https://example.com/app.ipa"), text: $addURLText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        let pasted = viewModel.initialURLFromPasteboard(currentText: "")
                        if !pasted.isEmpty {
                            Button {
                                addURLText = pasted
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundStyle(Color.userTint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(.localized("IPA URL"))
                } footer: {
                    Text(.localized("Paste a direct .ipa link. VexSign will download, unpack and let you sign it."))
                }

                Section {
                    Button(.localized("Download")) {
                        if viewModel.startDownload(fromRawURL: addURLText) {
                            addURLText = ""
                            showAddSheet = false
                        }
                    }
                    .disabled(addURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle(.localized("Download from URL"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(.localized("Cancel")) { showAddSheet = false } }
            }
            .onAppear {
                addURLText = viewModel.initialURLFromPasteboard(currentText: addURLText)
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Row

private struct DownloadRow: View {
    let download: Download
    let onOpenStaging: () -> Void
    @StateObject private var model = DownloadProgressModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DownloadPhaseRing(phase: model.phase, progress: model.phaseProgress, size: 28, lineWidth: 2.6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(download.fileName).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    HStack(spacing: 4) {
                        Image(systemName: model.phase.icon).font(.caption2)
                        Text(model.phase.title).font(.caption)
                        if let detail = model.phase.processingDetail {
                            Text("• \(detail)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .foregroundStyle(model.phase.tint)
                }
                Spacer()
                if model.phase == .completed {
                    Button {
                        onOpenStaging()
                        Toast.info(.localized("Opened staging folder"), systemImage: "folder")
                    } label: {
                        Label(.localized("Open"), systemImage: "folder.fill").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered).tint(Theme.tint).controlSize(.mini)
                } else {
                    Menu {
                        if download.canPause && download.isPaused {
                            Button(.localized("Resume"), systemImage: "play.fill") { DownloadManager.shared.resumeDownload(download) }
                        } else if download.canPause {
                            Button(.localized("Pause"), systemImage: "pause.fill") { DownloadManager.shared.pauseDownload(download) }
                        }
                        if download.canCancel {
                            Button(.localized("Cancel"), systemImage: "xmark", role: .destructive) { DownloadManager.shared.cancelDownload(download) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.body).foregroundStyle(.secondary)
                    }
                }
            }
            DownloadPhaseBar(phase: model.phase, progress: model.phaseProgress)
            HStack {
                Text("\(Int(model.phaseProgress * 100))%").font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(model.phase.tint)
                Spacer()
                if model.showsByteCount && model.totalBytes > 0 {
                    Text("\(model.bytesDownloaded.formattedByteCount) / \(model.totalBytes.formattedByteCount)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else if let detail = model.phase.processingDetail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if DownloadManager.shared.currentDownloadSpeed > 0 && model.phase == .downloading {
                    Text(verbatim: DownloadManager.shared.currentDownloadSpeed.formattedByteCount + "/s").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { model.bind(to: download) }
    }
}
