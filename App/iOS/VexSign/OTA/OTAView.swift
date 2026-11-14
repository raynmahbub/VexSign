import SwiftUI
import UniformTypeIdentifiers
import NimbleExtensions

private struct OTAManifestFile: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct OTAView: View {
	@State private var name = ""
	@State private var bundleID = ""
	@State private var version = "1.0"
	@State private var download = ""
	@State private var manifest = ""
	@State private var signedApps: [AppInfoPresentable] = []
	@State private var link: URL?
	@State private var qr: UIImage?
	@State private var file = OTAManifestFile(data: Data())
	@State private var exporting = false
	@State private var error: String?
	var body: some View {
		Form {
			Section(.localized("Hosted Signed IPA")) {
				if !signedApps.isEmpty {
					Menu {
						ForEach(signedApps, id: \.uuid) { app in
							Button {
								prefill(from: app)
							} label: {
								Text(app.name ?? .localized("Untitled"))
							}
						}
					} label: {
						Label(.localized("Prefill from Signed Apps"), systemImage: "square.and.arrow.down.on.square")
					}
				}
				TextField("App name", text: $name)
                TextField("Bundle identifier", text: $bundleID)
                TextField("Version", text: $version)
                TextField(.localized("HTTPS IPA URL"), text: $download)
                TextField(.localized("HTTPS manifest URL"), text: $manifest)
                Text(.localized("Host the exported manifest at exactly this URL. OTA still requires a valid signature and a profile that permits the device; generating a link does not sign an app.")).font(.caption)
                Button(.localized("Generate Manifest & Install Link")) {
                    do {
                        guard let downloadURL = URL(string: download), let manifestURL = URL(string: manifest) else { throw URLError(.badURL) }
                        file = OTAManifestFile(data: try OTAExporter.manifest(.init(name: name, bundleIdentifier: bundleID, version: version, downloadURL: downloadURL, iconURL: nil)))
                        let install = try OTAExporter.installLink(manifestURL: manifestURL)
                        link = install; qr = OTAExporter.qrCode(install); exporting = true; error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            if let link {
                Section("Install") {
                    ShareLink(item: link)
                    Button(.localized("Copy Link")) { UIPasteboard.general.url = link }
                    if let qr { Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 240).accessibilityLabel(.localized("Install QR code")) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.textInputAutocapitalization(.never).autocorrectionDisabled().navigationTitle(.localized("OTA Distribution"))
            .onAppear {
                if signedApps.isEmpty {
                    signedApps = Storage.shared.getAllApps().filter { $0.isSigned }
                }
            }
            .fileExporter(isPresented: $exporting, document: file, contentType: .xml, defaultFilename: "manifest.plist") { result in
                if case .failure(let error) = result { self.error = error.localizedDescription }
            }
    }

    private func prefill(from app: AppInfoPresentable) {
        name = app.name ?? ""
        bundleID = app.identifier ?? ""
        version = app.version ?? "1.0"
    }
}
