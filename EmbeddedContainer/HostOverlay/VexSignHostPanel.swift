import SwiftUI
import CryptoKit

struct VexSignEmbeddedManifest: Decodable {
    let bundleIdentifier: String
    let version: String
    let build: String
    let sha256: String
}

private func verifyEmbeddedVexSign(_ url: URL, digest: String) throws {
    let file = try FileHandle(forReadingFrom: url)
    defer { file.closeFile() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
        hash.update(data: data)
    }
    let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard actual == digest else {
        throw NSError(domain: "VexSignContainer", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The embedded VexSign archive failed its integrity check. Reinstall the combined app from a trusted build."
        ])
    }
}

/// Compiled into LiveContainerSwiftUI, not an external-app launcher.
/// Installation and launch callbacks use the host's normal patch/sign/load path.
struct VexSignHostPanel: View {
    let busy: Bool
    let installedBundleIdentifiers: [String]
    let install: (URL) async -> Bool
    let launch: (String) async -> Void
    @State private var manifest: VexSignEmbeddedManifest?
    @State private var verifying = false
    @State private var error: String?
    @State private var pendingPath: String?

    private var isPrimaryHost: Bool { Bundle.main.object(forInfoDictionaryKey: "VexSignPrimaryHost") as? Bool == true }

    private var isInstalled: Bool {
        guard let manifest else { return false }
        return installedBundleIdentifiers.contains(manifest.bundleIdentifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VexSign + LiveContainer + SideStore").font(.headline)
            Text(isPrimaryHost
                 ? "VexSign is the native primary interface. LiveContainer and SideStore are explicitly selected sessions. Configure supported signing/JIT before running guests."
                 : "All three are included in this app. VexSign runs in an isolated guest container; SideStore handles its own account and renewal. Configure the host's signing certificate or supported JIT mode before running guests.")
                .font(.caption).foregroundStyle(.secondary)
            if isPrimaryHost {
                Button("Return to VexSign") {
                    if !LCSharedUtils.vexSignOpenPrimary() { error = "The native primary session could not be requested." }
                }
            } else if let manifest {
                Text("Embedded VexSign \(manifest.version) (\(manifest.build))").font(.caption)
                if isInstalled {
                    Button("Open VexSign") { Task { await launch(manifest.bundleIdentifier) } }
                }
                Button(isInstalled ? "Update from embedded VexSign" : "Install embedded VexSign") {
                    Task { await installEmbedded() }
                }
                Text("Updates use LiveContainer's replacement prompt so an existing data container can be retained. Signing errors are shown by the host; adding a guest does not prove it can run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if pendingPath != nil {
                Button("Import IPA prepared in VexSign") { Task { await importPending() } }
                Button("Discard prepared import", role: .destructive) { discardPending() }
            }
            if verifying { ProgressView("Verifying embedded archive…") }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("Combined build source references and license notices are included under VexSignSources in this app bundle. The runtime and SideStore are AGPL-3.0 components.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .disabled(busy || verifying)
        .task {
            do {
                let url = Bundle.main.bundleURL.appendingPathComponent("VexSignEmbedded.json")
                manifest = try JSONDecoder().decode(VexSignEmbeddedManifest.self, from: Data(contentsOf: url))
                pendingPath = UserDefaults.standard.string(forKey: "VexSignPendingImport")
            } catch { self.error = error.localizedDescription }
        }
    }

    @MainActor
    private func installEmbedded() async {
        guard !busy, !verifying, let manifest else { return }
        verifying = true
        error = nil
        defer { verifying = false }
        let url = Bundle.main.bundleURL.appendingPathComponent("VexSign.ipa")
        do {
            let digest = manifest.sha256
            try await Task.detached(priority: .userInitiated) { try verifyEmbeddedVexSign(url, digest: digest) }.value
            _ = await install(url)
        } catch { self.error = error.localizedDescription }
    }

    private func validatedPendingURL() throws -> URL {
        guard let pendingPath else { throw CocoaError(.fileNoSuchFile) }
        let url = URL(fileURLWithPath: pendingPath).standardizedFileURL.resolvingSymlinksInPath()
        let inbox = LCPath.docPath.appendingPathComponent("Inbox").standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard url.deletingLastPathComponent() == inbox,
              url.lastPathComponent.hasPrefix("VexSign-"), url.pathExtension.lowercased() == "ipa",
              values.isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
        return url
    }

    @MainActor
    private func importPending() async {
        guard !busy, !verifying else { return }
        error = nil
        do {
            let url = try validatedPendingURL()
            if await install(url) { discardPending() }
        } catch { self.error = error.localizedDescription }
    }

    private func discardPending() {
        do {
            let url = try validatedPendingURL()
            try FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: "VexSignPendingImport")
            pendingPath = nil
        } catch {
            // Never delete a path that fails inbox containment validation.
            self.error = error.localizedDescription
            UserDefaults.standard.removeObject(forKey: "VexSignPendingImport")
            pendingPath = nil
        }
    }
}
