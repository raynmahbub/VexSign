// MARK: - Application sources, catalog discovery and updates
//
// Every row is backed by a validated, persisted `CatalogSnapshot`, a registered
// source, or a real installed-app/version comparison. No placeholder catalog
// entries, ratings or simulated transfer progress are used here.

import SwiftUI
import NimbleViews
import NimbleExtensions

struct CatalogWorkspaceView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var model: CatalogWorkspaceModel?
    @State private var section: CatalogSection = .sources
    @State private var isAddingSource = false
    @State private var selectedApp: CatalogAppRecord?
    @State private var selectedSource: CatalogSourceRecord?
    @State private var editingSource: CatalogSourceRecord?
    @State private var pendingEditSource: CatalogSourceRecord?

    private enum CatalogSection: String, CaseIterable, Identifiable {
        case sources, discover, updates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sources: String.localized("Sources")
            case .discover: String.localized("Discover")
            case .updates: String.localized("Updates")
            }
        }
    }

    var body: some View {
        NBNavigationView(String.localized("Application Sources"), displayMode: .inline) {
            Group {
                if let model = model { content(model: model) }
            }
        }
        .task {
            if model == nil { model = CatalogWorkspaceModel(container: container) }
            await model?.load()
        }
    }

    @ViewBuilder
    private func content(model: CatalogWorkspaceModel) -> some View {
            VStack(spacing: 0) {
                Picker(String.localized("Section"), selection: $section) {
                    ForEach(CatalogSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                List {
                    switch section {
                    case .sources: sourcesSection(model: model)
                    case .discover: discoverSection(model: model)
                    case .updates: updatesSection(model: model)
                    }
                }
                .listStyle(.insetGrouped)
                .dismissableKeyboard()
                .overlay { if model.isBusy { ProgressView().padding(.bottom, 24) } }
            }
            .searchable(text: Binding(
                get: { model.query.text },
                set: { model.query.text = $0; model.search() }
            ), placement: .navigationBarDrawer(displayMode: .always), prompt: Text(String.localized("Name, bundle ID or developer")))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await model.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.isBusy)
                    .accessibilityLabel(Text(String.localized("Refresh all sources")))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingSource = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text(String.localized("Add source")))
                }
            }
            .sheet(isPresented: $isAddingSource) {
                CatalogAddSourceView(model: model)
            }
            .sheet(item: $selectedApp) { app in
                CatalogAppDetailView(app: app, model: model)
            }
            .sheet(item: $selectedSource, onDismiss: {
                // Present the editor only after the detail sheet has closed; SwiftUI
                // does not reliably stack two sheets from the same presenter.
                if let source = pendingEditSource {
                    pendingEditSource = nil
                    editingSource = source
                }
            }) { source in
                CatalogSourceDetailView(source: source, onEdit: { pendingEditSource = $0 }, model: model)
            }
            .sheet(item: $editingSource) { source in
                CatalogSourceEditView(source: source, model: model)
            }
            .alert(String.localized("Catalog"), isPresented: Binding(
                get: { model.message != nil },
                set: { if !$0 { model.message = nil } }
            )) {
                Button(String.localized("OK"), role: .cancel) { }
            } message: {
                Text(model.message ?? "")
            }
        }

    private func sourcesSection(model: CatalogWorkspaceModel) -> some View {
        Section {
            ForEach(model.sources) { source in
                Button {
                    selectedSource = source
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name).font(.headline)
                            Text(source.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text(source.health.availability.rawValue.capitalized)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("\(source.applicationCount)")
                                .font(.caption.monospacedDigit())
                            Text(source.enabled ? String.localized("Enabled") : String.localized("Disabled"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(String.localized("Configured Sources"))
        } footer: {
            Text(String.localized("A source is only healthy after its catalog validated. HTTPS and provenance are reported separately; an unsigned feed is never called cryptographically trusted."))
                .font(.footnote)
        }
    }

    private func discoverSection(model: CatalogWorkspaceModel) -> some View {
        Section {
            TextField(String.localized("Developer"), text: Binding(
                get: { model.query.developer },
                set: { model.query.developer = $0; model.search() }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if model.hits.isEmpty {
                Text(String.localized("No catalog applications match this search."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(model.hits) { hit in
                Button {
                    selectedApp = hit.selected
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.name).font(.headline)
                        HStack {
                            Text(hit.bundleKey).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if let version = hit.selected?.currentVersion {
                                Text(version).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let developer = hit.developer {
                            Text(developer).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let source = hit.selected?.sourceName {
                            Text(String.localized("Source: %@", arguments: source))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(hit.selected == nil)
            }
        } header: {
            HStack {
                Text(String.localized("Applications"))
                Spacer()
                Menu {
                    Picker(String.localized("Sort"), selection: Binding(
                        get: { model.query.sort },
                        set: { model.query.sort = $0; model.search() }
                    )) {
                        ForEach(CatalogSearchQuery.Sort.allCases, id: \.self) { sort in
                            Text(sort.displayName).tag(sort)
                        }
                    }
                    Button {
                        model.query.ascending.toggle()
                        model.search()
                    } label: {
                        Label(model.query.ascending ? String.localized("Ascending") : String.localized("Descending"),
                              systemImage: model.query.ascending ? "arrow.up" : "arrow.down")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                Menu {
                    ForEach(model.sources) { source in
                        Toggle(source.name, isOn: Binding(
                            get: { model.query.sourceIDs.contains(source.id) },
                            set: { enabled in
                                if enabled { model.query.sourceIDs.insert(source.id) }
                                else { model.query.sourceIDs.remove(source.id) }
                                model.search()
                            }
                        ))
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    private func updatesSection(model: CatalogWorkspaceModel) -> some View {
        Section {
            let available = model.updates.filter { $0.verdict == .updateAvailable }
            if available.isEmpty {
                Text(String.localized("No compatible catalog updates were found for library apps."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(available) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.installedName).font(.headline)
                    Text(String.localized("%@ → %@", arguments: candidate.installedVersion ?? "?", candidate.release.version))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(candidate.app.sourceName).font(.caption2).foregroundStyle(.secondary)
                    Button {
                        model.updateDownload(candidate)
                    } label: {
                        Label(String.localized("Download Update"), systemImage: "arrow.down.circle")
                    }
                    .disabled(candidate.release.downloadURL.isEmpty)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(String.localized("Available Updates"))
        } footer: {
            Text(String.localized("Updates are compared by bundle identifier and version. An update is not assumed compatible until its minimum iOS version, source identity and signing identity are checked."))
                .font(.footnote)
        }
    }

}
private struct CatalogAddSourceView: View {
    @ObservedObject var model: CatalogWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var format: CatalogSourceFormat = .altStore

    var body: some View {
        NBNavigationView(String.localized("Add Source"), displayMode: .inline) {
            Form {
                Section(String.localized("Repository")) {
                    TextField(String.localized("Source URL"), text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker(String.localized("Format"), selection: $format) {
                        ForEach(CatalogSourceFormat.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section {
                    Text(String.localized("The catalog is fetched, parsed and validated before it is saved. A reachable URL alone does not create a source."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String.localized("Add")) {
                        Task {
                            await model.addSource(address: address, format: format)
                            dismiss()
                        }
                    }
                    .disabled(address.isEmpty || model.isBusy)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(String.localized("Cancel")) { dismiss() }
                }
            }
        }
    }
}

private struct CatalogSourceDetailView: View {
    let source: CatalogSourceRecord
    let onEdit: (CatalogSourceRecord) -> Void
    @ObservedObject var model: CatalogWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NBNavigationView(source.name, displayMode: .inline) {
            List {
                Section(String.localized("Identity")) {
                    LabeledContent(String.localized("Address"), value: source.url)
                    LabeledContent(String.localized("Format"), value: source.format.displayName)
                    LabeledContent(String.localized("Schema"), value: source.schemaVersion.map(String.init) ?? String.localized("Unknown"))
                    LabeledContent(String.localized("Applications"), value: "\(source.applicationCount)")
                    LabeledContent(String.localized("Integrity"), value: source.integrityVerified
                                   ? String.localized("Signature verified") : String.localized("Unsigned / unverified"))
                }
                Section(String.localized("Health")) {
                    LabeledContent(String.localized("Status"), value: source.health.availability.rawValue.capitalized)
                    LabeledContent(String.localized("Last success"), value: source.health.lastSuccessfulRefresh?.formatted() ?? String.localized("Never"))
                    LabeledContent(String.localized("Last failure"), value: source.health.lastFailedRefresh?.formatted() ?? String.localized("Never"))
                    LabeledContent(String.localized("Consecutive failures"), value: "\(source.health.consecutiveFailures)")
                    LabeledContent(String.localized("HTTP failures"), value: "\(source.health.httpFailures)")
                    LabeledContent(String.localized("Parse failures"), value: "\(source.health.parseFailures)")
                    LabeledContent(String.localized("Schema failures"), value: "\(source.health.schemaFailures)")
                    if let error = source.health.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                Section {
                    Button {
                        onEdit(source)
                        dismiss()
                    } label: {
                        Label(String.localized("Edit Metadata"), systemImage: "square.and.pencil")
                    }
                    Button {
                        Task {
                            await model.refresh(source)
                            dismiss()
                        }
                    } label: {
                        Label(String.localized("Refresh Source"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    Toggle(String.localized("Enabled"), isOn: Binding(
                        get: { source.enabled },
                        set: { model.setEnabled(source, enabled: $0) }
                    ))
                    Button(String.localized("Remove Source"), role: .destructive) {
                        model.removeSource(source)
                        dismiss()
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

private struct CatalogSourceEditView: View {
    let source: CatalogSourceRecord
    @ObservedObject var model: CatalogWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var summary: String
    @State private var artworkURL: String
    @State private var format: CatalogSourceFormat

    init(source: CatalogSourceRecord, model: CatalogWorkspaceModel) {
        self.source = source
        self.model = model
        _name = State(initialValue: source.name)
        _summary = State(initialValue: source.summary ?? "")
        _artworkURL = State(initialValue: source.artworkURL ?? "")
        _format = State(initialValue: source.format)
    }

    var body: some View {
        NBNavigationView(String.localized("Edit Source"), displayMode: .inline) {
            Form {
                Section(String.localized("Metadata")) {
                    TextField(String.localized("Display Name"), text: $name)
                    TextField(String.localized("Summary"), text: $summary, axis: .vertical)
                    TextField(String.localized("Artwork URL"), text: $artworkURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker(String.localized("Format"), selection: $format) {
                        ForEach(CatalogSourceFormat.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section {
                    Text(String.localized("Changing the format affects the next refresh. The last validated catalog stays available until a new one passes validation."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String.localized("Save")) {
                        Task {
                            await model.updateMetadata(source, name: name,
                                                       summary: summary.isEmpty ? nil : summary,
                                                       artworkURL: artworkURL.isEmpty ? nil : artworkURL,
                                                       format: format)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(String.localized("Cancel")) { dismiss() }
                }
            }
        }
    }
}

private struct CatalogAppDetailView: View {
    let app: CatalogAppRecord
    @ObservedObject var model: CatalogWorkspaceModel

    var body: some View {
        NBNavigationView(app.name, displayMode: .inline) {
            List {
                Section {
                    if let icon = app.iconURL, let url = URL(string: icon) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(height: 120)
                    }
                    Text(app.description ?? app.summary ?? String.localized("No description supplied by this source."))
                        .font(.subheadline)
                    LabeledContent(String.localized("Bundle ID"), value: app.bundleIdentifier)
                    LabeledContent(String.localized("Developer"), value: app.developer ?? String.localized("Not supplied"))
                    LabeledContent(String.localized("Source"), value: app.sourceName)
                    LabeledContent(String.localized("Latest"), value: app.currentVersion ?? String.localized("Unknown"))
                } header: {
                    Text(String.localized("Application"))
                }
                if !app.screenshotURLs.isEmpty {
                    Section(String.localized("Screenshots")) {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(app.screenshotURLs, id: \.self) { url in
                                    if let imageURL = URL(string: url) {
                                        AsyncImage(url: imageURL) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: { ProgressView() }
                                        .frame(width: 140, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                    }
                }
                Section(String.localized("Release History")) {
                    ForEach(app.releases) { release in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(release.version).font(.headline)
                                Spacer()
                                if let date = release.date { Text(date).font(.caption2).foregroundStyle(.secondary) }
                            }
                            if let size = release.size {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let notes = release.changelog {
                                Text(notes).font(.caption).foregroundStyle(.secondary)
                            }
                            Button {
                                model.download(app, release: release)
                            } label: {
                                Label(String.localized("Download This Release"), systemImage: "arrow.down.circle")
                            }
                            .disabled(release.downloadURL.isEmpty)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    Text(String.localized("Metadata was supplied by a third-party source; it is not a cryptographic trust claim. The archive is validated by the existing download and import pipeline."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}
