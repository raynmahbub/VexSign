//
//  FilesTabView.swift
//  VexSign — Files like Ksign: storage ring + Quick Access with counts/sizes + context menus. Single nav bar + ViewModel.
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import UniformTypeIdentifiers

struct FilesTabView: View {
    /// False when embedded in a workspace or pushed from another navigation stack.
    var ownsNavigationStack: Bool = true
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var vm = FileBrowserViewModel(directory: URL.documentsDirectory)
    @ObservedObject private var storage = StorageManager.shared
    @State private var query = ""
    @State private var showHidden = false

    // Alerts for creating new folder and file
    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showingNewFileAlert = false
    @State private var newFileName = ""

    private struct QuickFolder: Identifiable {
        var id: String { url.standardizedFileURL.path }
        let title: String
        let icon: String
        let color: Color
        let url: URL
    }

    private var quickFolders: [QuickFolder] {
        [
            QuickFolder(title: .localized("Documents"), icon: "folder.fill", color: Color(red: 0.0, green: 0.48, blue: 1.0), url: URL.documentsDirectory),
            QuickFolder(title: .localized("Downloads"), icon: "arrow.down.circle.fill", color: Color(red: 0.12, green: 0.65, blue: 0.95), url: FileManager.default.downloadStaging),
            QuickFolder(title: .localized("Archives"), icon: "archivebox.fill", color: Color(red: 0.55, green: 0.36, blue: 0.96), url: FileManager.default.archives),
            QuickFolder(title: .localized("Certificates"), icon: "checkmark.seal.fill", color: Color(red: 0.20, green: 0.66, blue: 0.44), url: FileManager.default.certificates),
            QuickFolder(title: .localized("Signed"), icon: "app.badge.checkmark.fill", color: Color(red: 0.95, green: 0.55, blue: 0.15), url: FileManager.default.signed),
            QuickFolder(title: .localized("Tweaks"), icon: "wrench.and.screwdriver.fill", color: Color(red: 0.96, green: 0.33, blue: 0.26), url: FileManager.default.tweaksLibrary),
        ]
    }

    var body: some View {
        // ONE navigation bar — NBNavigationView is the only NavigationStack in this tab
        NBNavigationView(.localized("Files"), displayMode: .large, ownsNavigationStack: ownsNavigationStack) {
            List {
                storageHeader
                quickAccessSection
                browseSection
                if !vm.visible.isEmpty { filesListSection }
                infoSection
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text(.localized("Search files")))
            .onChange(of: query) { _, newQuery in vm.query = newQuery }
            .onChange(of: showHidden) { _, newValue in vm.showsHidden = newValue; vm.reload() }
            .toolbar { toolbar }
            .scrollIndicators(.hidden)
            .refreshable { vm.reload() }
            .onAppear { vm.reload() }
            .alert(.localized("New Folder"), isPresented: $showingNewFolderAlert) {
                TextField(.localized("Folder name"), text: $newFolderName)
                    .textInputAutocapitalization(.never)
                Button(.localized("Create")) {
                    if let _ = FileManagerActions.createFolder(named: newFolderName, in: URL.documentsDirectory) {
                        newFolderName = ""
                        vm.reload()
                    }
                }
                Button(.localized("Cancel"), role: .cancel) { newFolderName = "" }
            } message: {
                Text(.localized("Enter a name for the new folder in Documents."))
            }
            .alert(.localized("New File"), isPresented: $showingNewFileAlert) {
                TextField(.localized("File name (e.g. notes.txt)"), text: $newFileName)
                    .textInputAutocapitalization(.never)
                Button(.localized("Create")) {
                    if let _ = FileManagerActions.createTextFile(named: newFileName, in: URL.documentsDirectory) {
                        newFileName = ""
                        vm.reload()
                    }
                }
                Button(.localized("Cancel"), role: .cancel) { newFileName = "" }
            } message: {
                Text(.localized("Enter a file name for the empty file."))
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(.localized("New Folder"), systemImage: "folder.badge.plus") {
                    showingNewFolderAlert = true
                }
                Button(.localized("New Text File"), systemImage: "doc.badge.plus") {
                    showingNewFileAlert = true
                }
                Button(.localized("Import from Files…"), systemImage: "square.and.arrow.down") {
                    DocumentPicker.open([.item], multiple: true) { urls in
                        let count = FileManagerActions.importFiles(urls, into: URL.documentsDirectory)
                        Toast.success(.localized("%lld file(s) imported", arguments: count), systemImage: "tray.and.arrow.down")
                        vm.reload()
                    }
                }
                Divider()
                Toggle(.localized("Show Hidden"), isOn: $showHidden)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(Text(.localized("More")))
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                if let url = URL.documentsDirectory.toSharedDocumentsURL() {
                    UIApplication.open(url)
                }
            } label: {
                Label(.localized("Open in Files"), systemImage: "folder")
            }
            .accessibilityHint(Text(.localized("Open Documents in Files app")))
        }
    }

    // MARK: Storage header — Ksign storage gauge
    private var storageHeader: some View {
        Section {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Theme.tintSoft).frame(width: 48, height: 48)
                        Image(systemName: "internaldrive.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.tint)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("On My iPhone — VexSign")).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                        if let total = storage.report?.total {
                            Text(verbatim: total.formattedFileSize + " " + String.localized("used")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(.localized("Documents & data")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let report = storage.report {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(verbatim: report.total.formattedFileSize).font(.caption.weight(.semibold)).foregroundStyle(Theme.tint).monospacedDigit()
                            if let free = FileManager.default.availableImportantCapacity(at: URL.documentsDirectory) {
                                Text(verbatim: free.formattedFileSize + " " + String.localized("free")).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                if let report = storage.report {
                    GeometryReader { geo in
                        let used = Double(report.total)
                        let free = Double(FileManager.default.availableImportantCapacity(at: URL.documentsDirectory) ?? 0)
                        let cap = used + free
                        let pct: Double = cap > 0 ? min(max(used / cap, 0.06), 1) : 0.06
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.quaternary).frame(height: 6)
                            Capsule().fill(LinearGradient(colors: [Theme.tint, Theme.tintDeep], startPoint: .leading, endPoint: .trailing)).frame(width: geo.size.width * pct, height: 6)
                        }
                    }
                    .frame(height: 6)
                }
                HStack(spacing: 8) {
                    Label("\(quickFolders.count) locations", systemImage: "point.3.connected.trianglepath.dotted").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(.localized("On-device browser")).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Label(.localized("Storage"), systemImage: "internaldrive").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.tint)
        }
    }

    // MARK: Quick Access Grid (Ksign Style)
    private var quickAccessSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(quickFolders) { folder in
                    let count = vm.count(at: folder.url)
                    let size = vm.size(at: folder.url)
                    NavigationLink(destination: FileManagerView(directory: folder.url)) {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(folder.color.opacity(0.13)).frame(width: 44, height: 44)
                                Image(systemName: folder.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(folder.color)
                            }
                            Text(folder.title).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary).minimumScaleFactor(0.7)
                            Text(verbatim: "\(count) • \(size)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(.localized("Open in Files App"), systemImage: "folder") {
                            if let shared = folder.url.toSharedDocumentsURL() { UIApplication.open(shared) }
                        }
                        Button(.localized("Copy Path"), systemImage: "doc.on.doc") { FileManagerActions.copyPath(folder.url) }
                        if FileManager.default.fileExists(atPath: folder.url.path) {
                            Button(.localized("Share"), systemImage: "square.and.arrow.up") { FileManagerActions.share(folder.url) }
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        } header: {
            Label(.localized("Quick Access"), systemImage: "star.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.tint)
        } footer: {
            Text(.localized("Quick folders — tap to browse, long-press for actions."))
        }
    }

    // MARK: Browse Shortcuts
    private var browseSection: some View {
        Section {
            NavigationLink(destination: FileManagerView(directory: URL.documentsDirectory, isRoot: true)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Browse All Documents")).font(.subheadline.weight(.medium))
                        Text(.localized("All files, imports, archives and certificates")).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                } icon: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.tintSoft).frame(width: 32, height: 32)
                        Image(systemName: "folder.fill").foregroundStyle(Theme.tint)
                    }
                }
            }

            NavigationLink(destination: FileManagerView(directory: FileManager.default.downloadStaging)) {
                Label(.localized("Downloads Folder"), systemImage: "arrow.down.circle.fill").foregroundStyle(.primary)
            }
            NavigationLink(destination: FileManagerView(directory: FileManager.default.archives)) {
                Label(.localized("Archives"), systemImage: "archivebox.fill").foregroundStyle(.primary)
            }
            NavigationLink(destination: FileManagerView(directory: FileManager.default.certificates)) {
                Label(.localized("Certificates"), systemImage: "checkmark.seal.fill").foregroundStyle(.primary)
            }
            // Single back navigation bar: inNavigationStack: false
            NavigationLink(destination: IPSWBrowserView(inNavigationStack: false)) {
                Label(.localized("Firmware Browser"), systemImage: "opticaldisc.fill").foregroundStyle(.primary)
            }
            NavigationLink(destination: IPAExplorerHomeView()) {
                Label(.localized("IPA Explorer"), systemImage: "doc.text.magnifyingglass").foregroundStyle(.primary)
            }
        } header: {
            Label(.localized("Browse"), systemImage: "folder.badge.gearshape").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.tint)
        }
    }

    // MARK: Files List in Documents Root (Ksign Style)
    private var filesListSection: some View {
        Section {
            ForEach(vm.visible) { entry in
                if entry.kind == .directory {
                    NavigationLink(destination: FileManagerView(directory: entry.url)) {
                        fileRowView(entry: entry)
                    }
                } else {
                    NavigationLink(destination: FileManagerItemView(entry: entry)) {
                        fileRowView(entry: entry)
                    }
                    .contextMenu {
                        fileContextMenu(entry: entry)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            FileManagerActions.delete([entry.url])
                            vm.reload()
                        } label: {
                            Label(.localized("Delete"), systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            FileManagerActions.share(entry.url)
                        } label: {
                            Label(.localized("Share"), systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                }
            }
        } header: {
            HStack {
                Label(.localized("Files"), systemImage: "doc.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.tint)
                Spacer()
                Text("\(vm.visible.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fileRowView(entry: IPAFileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.systemImage)
                .font(.system(size: 20))
                .foregroundStyle(entry.kind.tint)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 6) {
                    Text(entry.size.formattedFileSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func fileContextMenu(entry: IPAFileEntry) -> some View {
        let ext = entry.url.pathExtension.lowercased()

        if ["ipa", "ksign", "zip"].contains(ext) {
            Button(.localized("Import to Library"), systemImage: "square.grid.2x2.fill") {
                _ = FileManagerActions.importFiles([entry.url], into: FileManager.default.unsigned)
                Toast.success(.localized("Imported to Library"), systemImage: "tray.and.arrow.down")
            }
        }

        if ["deb", "dylib"].contains(ext) {
            Button(.localized("Send to Tweak Manager"), systemImage: "wrench.and.screwdriver.fill") {
                FileManagerActions.sendToTweakManager(entry.url)
            }
        }

        Button(.localized("Share"), systemImage: "square.and.arrow.up") {
            FileManagerActions.share(entry.url)
        }

        Button(.localized("Duplicate"), systemImage: "plus.square.on.square") {
            FileManagerActions.duplicate(entry.url)
            vm.reload()
        }

        Button(.localized("Copy Path"), systemImage: "doc.on.doc") {
            FileManagerActions.copyPath(entry.url)
        }

        Divider()

        Button(role: .destructive) {
            FileManagerActions.delete([entry.url])
            vm.reload()
        } label: {
            Label(.localized("Delete"), systemImage: "trash")
        }
    }

    private var infoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(.localized("Using Files"), systemImage: "info.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(.localized("Files shows everything VexSign stores on-device. Long-press a row for rename, duplicate, share, copy hash and tweak actions. Swipe to delete. Use Quick Access above to browse your storage locations.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
