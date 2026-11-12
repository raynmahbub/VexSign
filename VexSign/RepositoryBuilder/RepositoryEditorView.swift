import SwiftUI
import UniformTypeIdentifiers
import NimbleExtensions

struct RepositoryJSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct RepositoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var document: RepositoryDocument
    var save: (RepositoryDocument) async throws -> Void
    @State private var issues: [RepositoryIssue] = []
    @State private var exportFile = RepositoryJSONFile(data: Data())
    @State private var exportName = "source"
    @State private var exporting = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            Section("Repository") {
                TextField("Name", text: $document.name)
                TextField("Identifier", text: $document.identifier).textInputAutocapitalization(.never)
                TextField(.localized("Icon URL"), text: $document.iconURL).textInputAutocapitalization(.never)
                Picker(.localized("Export format"), selection: $document.format) {
                    ForEach(RepositoryFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(.localized("Conversion uses the shared public JSON schema. Non-AltStore exports flatten release history to the selected version. Marketplace permissions and encrypted ESign feeds require provider-specific tooling.")).font(.caption).foregroundStyle(.secondary)
            }
            Section("Apps") {
                ForEach($document.apps) { $app in
                    NavigationLink { RepositoryAppEditor(app: $app) } label: { Text(app.name.isEmpty ? .localized("Untitled App") : app.name) }
                }.onDelete { document.apps.remove(atOffsets: $0) }
                Button(.localized("Add App")) { document.apps.append(RepositoryApp()) }
            }
            Section(.localized("Validation & Export")) {
                Button(.localized("Validate")) { issues = RepositoryValidator.validate(document) }
                Button(.localized("Check Download Links")) {
                    busy = true
                    Task {
                        issues = RepositoryValidator.validate(document) + (await RepositoryValidator.checkDownloads(document))
                        busy = false
                    }
                }
                Button(.localized("Apply Safe Fixes")) { RepositoryValidator.applySafeFixes(to: &document); issues = RepositoryValidator.validate(document) }
                Button(.localized("Export source.json")) { export(appsOnly: false) }
                Button(.localized("Export apps.json")) { export(appsOnly: true) }
                ForEach(issues) { issue in
                    VStack(alignment: .leading) {
                        Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                        Text(issue.suggestion).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .disabled(busy)
        .navigationTitle(document.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await save(document); dismiss() } catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy)
            }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json, defaultFilename: exportName) { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
    }
    private func export(appsOnly: Bool) {
        do {
            let files = try RepositoryExporter.encode(document, as: document.format)
            exportFile = RepositoryJSONFile(data: appsOnly ? files.apps : files.source)
            exportName = appsOnly ? "apps" : "source"
            exporting = true
        } catch { self.error = error.localizedDescription }
    }
}

private struct RepositoryAppEditor: View {
    @Binding var app: RepositoryApp
    var body: some View {
        Form {
            TextField("Name", text: $app.name)
            TextField("Bundle identifier", text: $app.bundleIdentifier)
            TextField("Version", text: $app.version)
            TextField(.localized("Version date (ISO 8601)"), text: $app.versionDate)
            TextField("Developer", text: $app.developerName)
            TextField("Category", text: $app.category)
            TextField(.localized("Tint color (hex)"), text: $app.tintColor)
            TextField(.localized("Download URL"), text: $app.downloadURL)
            TextField(.localized("Icon URL"), text: $app.iconURL)
            TextField(.localized("Size in bytes"), value: $app.size, format: .number).keyboardType(.numberPad)
            Section("Description") { TextEditor(text: $app.localizedDescription).frame(minHeight: 120) }
            Section(.localized("Screenshots (one URL per line)")) {
                TextEditor(text: Binding(get: { app.screenshotURLs.joined(separator: "\n") }, set: { app.screenshotURLs = $0.components(separatedBy: "\n").filter { !$0.isEmpty } })).frame(minHeight: 100)
            }
        }.textInputAutocapitalization(.never).autocorrectionDisabled().navigationTitle(.localized("App Details"))
    }
}
