//
//  DownloadsTabView.swift
//  VexSign — Downloads tab with proper functionality. Single nav bar.
//  Active downloads tracking + Finished IPAs management (Ksign style).
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import UniformTypeIdentifiers

struct DownloadsTabView: View {
    /// False when embedded in a workspace or pushed from another navigation stack.
    var ownsNavigationStack: Bool = true
    @StateObject private var downloadManager = DownloadManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var filter: Filter = .all
    @State private var showAddSheet = false
    @State private var addURLText = ""
    @State private var showImportPicker = false
    @State private var downloadedFiles: [DownloadedFile] = []

    struct DownloadedFile: Identifiable, Hashable {
        var id: String { url.path }
        let name: String
        let url: URL
        let size: Int64
        let date: Date

        var formattedSize: String {
            size.formattedByteCount
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case paused = "Paused"
        case completed = "Done"
        var id: String { rawValue }
        func matches(_ dl: Download) -> Bool {
            switch self {
            case .all: return true
            case .active: return dl.isActive && !dl.isPaused && dl.phase != .completed
            case .paused: return dl.isPaused
            case .completed: return dl.phase == .completed
            }
        }
    }

    private var filteredDownloads: [Download] {
        let list = downloadManager.downloads.filter(filter.matches)
        return list.reversed()
    }

    private var activeCount: Int { downloadManager.downloads.filter { $0.isActive && !$0.isPaused }.count }
    private var pausedCount: Int { downloadManager.downloads.filter { $0.isPaused }.count }
    private var completedCount: Int {
        downloadManager.downloads.filter { $0.phase == .completed }.count + downloadedFiles.count
    }

    var body: some View {
        // ONE navigation bar — NBNavigationView is the only NavigationStack in this tab
        NBNavigationView(.localized("Downloads"), displayMode: .large, ownsNavigationStack: ownsNavigationStack) {
            List {
                header
                filterPills

                if filteredDownloads.isEmpty && (filter != .all && filter != .completed || downloadedFiles.isEmpty) {
                    emptyState
                } else {
                    if !filteredDownloads.isEmpty {
                        activeDownloadsSection
                    }

                    if (filter == .all || filter == .completed) && !downloadedFiles.isEmpty {
                        downloadedFilesSection
                    }
                }

                actionsSection
            }
            .listStyle(.insetGrouped)
            .animation(.snappy, value: downloadManager.downloads.count)
            .animation(.snappy, value: filter)
            .animation(.snappy, value: downloadedFiles.count)
            .scrollIndicators(.hidden)
            .toolbar { toolbar }
            .refreshable {
                loadDownloadedFiles()
            }
            .onAppear {
                loadDownloadedFiles()
            }
            .sheet(isPresented: $showAddSheet) { addSheet }
            .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    let count = FileManagerActions.importFiles(urls, into: FileManager.default.downloadStaging)
                    Toast.success(.localized("%lld file(s) imported", arguments: count), systemImage: "tray.and.arrow.down")
                    loadDownloadedFiles()
                }
            }
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
                if !downloadManager.downloads.isEmpty || !downloadedFiles.isEmpty {
                    Divider()
                    Button(.localized("Pause All"), systemImage: "pause.fill") { downloadManager.pauseAllDownloads() }
                    Button(.localized("Resume All"), systemImage: "play.fill") { downloadManager.resumeAllDownloads() }
                    Divider()
                    Button(.localized("Clear Completed"), systemImage: "trash", role: .destructive) { clearCompleted() }
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
                        Text(verbatim: downloadManager.downloads.isEmpty && downloadedFiles.isEmpty ? String.localized("No downloads yet") : String.localized("%lld active • %lld completed", arguments: activeCount, completedCount))
                            .font(.caption).foregroundStyle(.secondary)
                        if downloadManager.currentDownloadSpeed > 0 {
                            Text(verbatim: downloadManager.currentDownloadSpeed.formattedByteCount + "/s")
                                .font(.caption2.weight(.medium)).foregroundStyle(Theme.tint).monospacedDigit()
                        }
                    }
                    Spacer()
                    let totalCount = downloadManager.downloads.count + downloadedFiles.count
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
                                    case .all: return downloadManager.downloads.count + downloadedFiles.count
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
                DownloadRow(download: dl)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if dl.canCancel {
                            Button(role: .destructive) { DownloadManager.shared.cancelDownload(dl) } label: { Label(.localized("Cancel"), systemImage: "xmark") }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if dl.isPaused {
                            Button { DownloadManager.shared.resumeDownload(dl) } label: { Label(.localized("Resume"), systemImage: "play.fill") }.tint(.green)
                        } else if dl.isActive {
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

    // MARK: - Downloaded / Finished IPAs (Ksign Downloader Style)
    private var downloadedFilesSection: some View {
        Section {
            ForEach(downloadedFiles) { item in
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
                            _ = FileManagerActions.importFiles([item.url], into: FileManager.default.unsigned)
                            Toast.success(.localized("Imported to Library"), systemImage: "tray.and.arrow.down")
                        } label: {
                            Label(.localized("Import to Library"), systemImage: "square.grid.2x2.fill")
                        }

                        Button {
                            FileManagerActions.share(item.url)
                        } label: {
                            Label(.localized("Share"), systemImage: "square.and.arrow.up")
                        }

                        Button {
                            if let shared = item.url.toSharedDocumentsURL() { UIApplication.open(shared) }
                        } label: {
                            Label(.localized("Open in Files"), systemImage: "folder")
                        }

                        Divider()

                        Button(role: .destructive) {
                            try? FileManager.default.removeItem(at: item.url)
                            loadDownloadedFiles()
                            Toast.success(.localized("Deleted"), systemImage: "trash")
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
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        try? FileManager.default.removeItem(at: item.url)
                        loadDownloadedFiles()
                    } label: {
                        Label(.localized("Delete"), systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        _ = FileManagerActions.importFiles([item.url], into: FileManager.default.unsigned)
                        Toast.success(.localized("Imported to Library"), systemImage: "tray.and.arrow.down")
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
                Text("\(downloadedFiles.count)")
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
            NavigationLink(destination: FileManagerView(directory: FileManager.default.downloadStaging)) {
                Label(.localized("Downloads Folder"), systemImage: "folder")
            }
            // Single back navigation bar: inNavigationStack: false
            NavigationLink(destination: LogsHistoryView(inNavigationStack: false)) {
                Label(.localized("Activity Logs"), systemImage: "text.alignleft")
            }
            if !downloadManager.downloads.isEmpty || !downloadedFiles.isEmpty {
                Button(.localized("Clear Completed"), systemImage: "trash", role: .destructive) { clearCompleted() }
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

                        if let clip = UIPasteboard.general.string, clip.hasPrefix("http") {
                            Button {
                                addURLText = clip.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        guard let url = URL(string: addURLText.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
                            Toast.error(.localized("Invalid URL")); return
                        }
                        _ = DownloadManager.shared.startDownload(from: url)
                        Toast.info(.localized("Download started"), systemImage: "arrow.down.circle")
                        addURLText = ""; showAddSheet = false
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
                if addURLText.isEmpty, let clip = UIPasteboard.general.string, clip.hasPrefix("http") {
                    addURLText = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func loadDownloadedFiles() {
        let staging = FileManager.default.downloadStaging
        do {
            try FileManager.default.createDirectoryIfNeeded(at: staging)
            let urls = try FileManager.default.contentsOfDirectory(
                at: staging,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            let files: [DownloadedFile] = urls.compactMap { url in
                guard ["ipa", "zip", "deb"].contains(url.pathExtension.lowercased()) else { return nil }
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(vals?.fileSize ?? 0)
                let date = vals?.contentModificationDate ?? Date()
                return DownloadedFile(name: url.lastPathComponent, url: url, size: size, date: date)
            }
            downloadedFiles = files.sorted { $0.date > $1.date }
        } catch {
            downloadedFiles = []
        }
    }

    private func clearCompleted() {
        let completed = downloadManager.downloads.filter { $0.phase == .completed }
        for dl in completed { DownloadManager.shared.cancelDownload(dl) }
        loadDownloadedFiles()
        Toast.success(.localized("Cleared completed downloads"), systemImage: "trash")
    }
}

// MARK: - Row

private struct DownloadRow: View {
    let download: Download
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
                        if let url = FileManager.default.downloadStaging.toSharedDocumentsURL() { UIApplication.open(url) }
                        Toast.info(.localized("Opened staging folder"), systemImage: "folder")
                    } label: {
                        Label(.localized("Open"), systemImage: "folder.fill").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered).tint(Theme.tint).controlSize(.mini)
                } else {
                    Menu {
                        if download.isPaused {
                            Button(.localized("Resume"), systemImage: "play.fill") { DownloadManager.shared.resumeDownload(download) }
                        } else if download.isActive {
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
