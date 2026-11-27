// MARK: - Application containers UI
//
// These screens are a view over VexSign-owned storage. They never describe a
// container as an installed iOS app sandbox or claim that a hand-off launched
// anything.

import SwiftUI
import UniformTypeIdentifiers
import NimbleViews
import NimbleExtensions

struct ContainerWorkspaceView: View {
    @EnvironmentObject private var services: AppContainer
    @State private var model: ContainerWorkspaceModel?
    @State private var isCreating = false
    @State private var isRestoring = false
    @State private var restoreFile: URL?
    @State private var restorePassword = ""

    var body: some View {
        NBNavigationView(.localized("Containers"), displayMode: .inline) {
            Group {
                if let model {
                    content(model: model)
                } else {
                    ProgressView()
                }
            }
        }
        .task {
            if model == nil {
                model = ContainerWorkspaceModel(
                    workspaceProvider: { [weak services] in services?.workspace.snapshot ?? .empty }
                )
            }
            await model?.load()
        }
    }

    @ViewBuilder
    private func content(model: ContainerWorkspaceModel) -> some View {
        List {
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            if let message = model.message {
                Section {
                    Text(message).foregroundStyle(.green).font(.footnote)
                }
            }
            Section {
                Text(.localized("These are VexSign-owned storage containers inside the app sandbox. They are not iOS application sandboxes, installed apps or running processes."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if model.filtered.isEmpty {
                    Text(.localized("No containers yet. Create one to group files and preferences for a library app."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(model.filtered) { container in
                    NavigationLink {
                        ContainerDetailView(container: container, model: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(container.displayName).font(.headline)
                                Spacer()
                                Text(container.state.title).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(container.detail.isEmpty ? .localized("No description") : container.detail)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Text(container.application?.name ?? .localized("No associated app"))
                                Spacer()
                                Text(container.formattedSize).font(.caption.monospacedDigit())
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text(.localized("Managed Containers"))
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: Binding(
            get: { model.searchText },
            set: { model.searchText = $0 }
        ), prompt: Text(.localized("Name, app or bundle identifier")))
        .overlay { if model.isBusy { ProgressView().padding(.bottom, 24) } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text(.localized("Create container")))
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isRestoring = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel(Text(.localized("Restore container")))
            }
        }
        .sheet(isPresented: $isCreating) {
            ContainerCreateView(model: model)
        }
        .fileImporter(isPresented: $isRestoring, allowedContentTypes: [.data, .zip, .packageArchives]) { result in
            switch result {
            case .success(let url): restoreFile = url
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .sheet(item: $restoreFile) { file in
            ContainerRestoreView(file: file, password: $restorePassword, model: model)
        }
    }
}

private struct ContainerCreateView: View {
    @ObservedObject var model: ContainerWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var detail = ""

    var body: some View {
        NBNavigationView(.localized("New Container"), displayMode: .inline) {
            Form {
                Section(.localized("Identity")) {
                    TextField(.localized("Display Name"), text: $name)
                    TextField(.localized("Description"), text: $detail, axis: .vertical)
                }
                Section {
                    Text(.localized("The container is created in VexSign's sandbox. It is storage only; it cannot run code or become an iOS app sandbox."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(.localized("Create")) {
                        Task {
                            if await model.create(name: name, detail: detail) != nil { dismiss() }
                        }
                    }
                    .disabled(name.isEmpty || model.isBusy)
                }
                ToolbarItem(placement: .topBarCancellation) {
                    Button(.localized("Cancel")) { dismiss() }
                }
            }
        }
    }
}

private struct ContainerRestoreView: View {
    let file: URL
    @Binding var password: String
    @ObservedObject var model: ContainerWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ContainerExportManifest?
    @State private var replaceExisting = false

    var body: some View {
        NBNavigationView(.localized("Restore Container"), displayMode: .inline) {
            Form {
                Section(.localized("Archive")) {
                    Text(file.lastPathComponent).font(.caption)
                    TextField(.localized("Password (if encrypted)"), text: $password)
                        .textInputAutocapitalization(.never)
                }
                if let preview {
                    Section(.localized("Preview")) {
                        LabeledContent(.localized("Name"), value: preview.container.displayName)
                        LabeledContent(.localized("Resources"), value: "\(preview.container.resources.count)")
                        LabeledContent(.localized("Version"), value: String(preview.schemaVersion))
                    }
                    Section {
                        Toggle(.localized("Replace matching container"), isOn: $replaceExisting)
                        Text(.localized("Replacement is destructive and only accepts the exact container id from this archive."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(.localized("Restore")) {
                        Task {
                            await model.restore(file: file, password: password.isEmpty ? nil : password,
                                                replaceID: replaceExisting ? preview?.container.id : nil)
                            dismiss()
                        }
                    }
                    .disabled(preview == nil || model.isBusy)
                }
                ToolbarItem(placement: .topBarCancellation) {
                    Button(.localized("Cancel")) { dismiss() }
                }
            }
            .task {
                preview = await model.preview(file: file, password: password.isEmpty ? nil : password)
            }
        }
    }
}

private struct ContainerDetailView: View {
    @ObservedObject var model: ContainerWorkspaceModel
    let container: AppContainerRecord
    @State private var containerName: String
    @State private var detail: String
    @State private var exportPassword = ""
    @State private var isExporting = false
    @State private var isImportingResource = false
    @State private var showDelete = false
    @State private var exportDocument = ContainerArchiveFile(data: Data())
    @State private var handoffRoute: ContainerHandoffRoute = .liveContainerURLScheme

    init(container: AppContainerRecord, model: ContainerWorkspaceModel) {
        self.container = container
        self.model = model
        _containerName = State(initialValue: container.displayName)
        _detail = State(initialValue: container.detail)
    }

    var body: some View {
        List {
            Section(.localized("Identity")) {
                TextField(.localized("Display Name"), text: $containerName)
                TextField(.localized("Description"), text: $detail, axis: .vertical)
                Button(.localized("Save Metadata")) {
                    Task {
                        if containerName != container.displayName {
                            await model.rename(container, to: containerName)
                        }
                        await model.updateDetail(container, detail: detail)
                    }
                }
                LabeledContent(.localized("Identifier"), value: container.id)
                LabeledContent(.localized("State"), value: container.state.title)
                LabeledContent(.localized("Schema"), value: String(container.schemaVersion))
            }

            Section(.localized("Associated Application")) {
                Picker(.localized("Library App"), selection: Binding(
                    get: { container.application?.recordID ?? "" },
                    set: { id in
                        let app = model.libraryApps.first { $0.recordID == id }
                        Task { await model.associate(container, app: app) }
                    }
                )) {
                    Text(.localized("None")).tag("")
                    ForEach(model.libraryApps) { app in
                        Text(app.name ?? app.identifier ?? app.recordID ?? "?").tag(app.recordID ?? "")
                    }
                }
                if let app = container.application {
                    LabeledContent(.localized("Bundle ID"), value: app.bundleIdentifier ?? .localized("Unknown"))
                    LabeledContent(.localized("Recorded Version"), value: app.version ?? .localized("Unknown"))
                }
                Text(.localized("Association is metadata only. It does not prove that the app is installed or running."))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section(.localized("Preferences")) {
                ForEach(container.preferences.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: container.preferences[key]?.displayValue ?? "")
                }
                Button(.localized("Set a Local Preference")) {
                    Task { await model.setPreference(container, key: "note", value: .text(.localized("Set on this device"))) }
                }
            }

            Section(.localized("Resources")) {
                ForEach(container.resources) { resource in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(resource.fileName).font(.subheadline)
                            Text("\(resource.formattedSize) · \(resource.typeIdentifier ?? .localized("File"))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.removeResource(container, path: resource.relativePath) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(Text(.localized("Remove resource")))
                    }
                }
                Button(.localized("Add File")) { isImportingResource = true }
            }

            Section(.localized("Storage")) {
                LabeledContent(.localized("Allocated Size"), value: model.usage[container.id]?.formatted ?? container.formattedSize)
                LabeledContent(.localized("Declared Size"), value: container.formattedSize)
                LabeledContent(.localized("File Count"), value: "\(model.usage[container.id]?.fileCount ?? container.resources.count)")
            }

            Section(.localized("Export and Hand-off")) {
                SecureField(.localized("Optional export password"), text: $exportPassword)
                Button {
                    Task {
                        if let document = await model.exportDocument(
                            container, password: exportPassword.isEmpty ? nil : exportPassword
                        ) {
                            exportDocument = document
                            isExporting = true
                        }
                    }
                } label: {
                    Label(.localized("Export Container"), systemImage: "square.and.arrow.up")
                }
                Picker(.localized("Hand-off"), selection: $handoffRoute) {
                    ForEach(ContainerHandoffRoute.allCases, id: \.self) { route in
                        Text(route == .embeddedHost ? .localized("Embedded host") : .localized("LiveContainer URL scheme")).tag(route)
                    }
                }
                Button {
                    Task { await model.handoff(route: handoffRoute, container: container) }
                } label: {
                    Label(.localized("Request Hand-off"), systemImage: "arrow.up.forward.app")
                }
                Text(.localized("A hand-off is a request to another application. VexSign cannot verify a launch, signing result or installation from the URL callback."))
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) { showDelete = true } label: {
                    Label(.localized("Delete Container"), systemImage: "trash")
                }
            }
        }
        .listStyle(.insetGrouped)
        .dismissableKeyboard()
        .fileImporter(isPresented: $isImportingResource, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): Task { await model.addResource(container, from: url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument,
                      contentType: UTType(filenameExtension: "vexcontainer") ?? .data,
                      defaultFilename: container.displayName + ".vexcontainer") { _ in }
        .alert(.localized("Delete Container"), isPresented: $showDelete) {
            Button(.localized("Delete"), role: .destructive) {
                Task { await model.delete(container) }
            }
            Button(.localized("Cancel"), role: .cancel) { }
        } message: {
            Text(.localized("This permanently removes the container's files inside VexSign. It does not uninstall any app."))
        }
    }
}
