import SwiftUI
import NimbleViews
import NimbleExtensions
import UIKit

import UniformTypeIdentifiers

struct CompanionSigningWorkflowView: View {
    var libraryApp: AnyApp? = nil
    @State private var preparingLibraryIPA = false
    @State private var stagingFileIPA = false
    @State private var stagingCopyTask: Task<URL, Error>?
    @State private var hashingIPA = false
    @State private var ipaFingerprint: String?
    @State private var expectedFingerprint = ""
    private var integrity: CompanionIPAIntegrity {
        CompanionIPAIntegrity.evaluate(expected: expectedFingerprint, actual: ipaFingerprint)
    }
    @State private var preparingEmbeddedIPA = false
    private var embedded: Bool { EmbeddedContainerRuntime.isAvailable }
    private var preparingIPA: Bool { preparingLibraryIPA || stagingFileIPA || hashingIPA || preparingEmbeddedIPA }
    @StateObject private var archiveStatus = InstallerStatusViewModel(isIdevice: false)
    @State private var exportTask: UnifiedTask?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sideStoreAvailable = false
    @State private var liveContainerAvailable = false
    @State private var hostedIPA = ""
    @State private var showImporter = false
    @State private var sharedIPA: URL?
    @State private var errorMessage: String?
    @State private var confirmHandoff = false
    @State private var requestOpened = false

    private var installLink: URL? { CompanionHandoffLink.sideStoreInstall(hostedIPA) }

    var body: some View {
        NBList(.localized("SideStore & LiveContainer")) {
            if embedded { EmbeddedContainerControls().disabled(preparingIPA) }
            if EmbeddedContainerRuntime.isGuestBuild && !embedded {
                Section {
                    Label(.localized("Embedded runtime unavailable"), systemImage: "exclamationmark.triangle")
                    Text(.localized("Launch this guest from the compatible VexSign Container in main-process mode. External app launchers are not substituted for a missing embedded runtime."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup(.localized("How the apps work together")) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        Label(.localized("VexSign prepares and shares IPA files"), systemImage: "archivebox")
                        Label(.localized("SideStore manages its Apple account, installs and renewals"), systemImage: "checkmark.seal")
                        Label(.localized("LiveContainer imports and runs compatible guests"), systemImage: "square.stack")
                        Text(EmbeddedContainerRuntime.isGuestBuild
                             ? .localized("This build includes the host and SideStore. VexSign runs as a guest; data and accounts remain isolated. Use the built-in controls to switch sessions or prepare a local guest import.")
                             : .localized("These are separate apps. Credentials, libraries and completion status are not automatically synchronized."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding(.vertical, Theme.Spacing.small)
                }
                NavigationLink(destination: CompanionSetupDiagnosticsView()) {
                    Label(.localized("Companion Setup Diagnostics"), systemImage: "stethoscope")
                }
            }
            if requestOpened {
                Section {
                    Label(.localized("Companion request opened"), systemImage: "arrow.up.forward.app")
                    Text(.localized("iOS accepted the open request. Installation, account login and renewal are not verified. Check the result inside the companion app."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(.localized("Dismiss status")) { requestOpened = false }
                }
            }
            if !EmbeddedContainerRuntime.isGuestBuild {
            Section {
                Text(.localized("Apple-account login stays in SideStore"))
                    .font(.headline)
                Text(.localized("Sign in and complete two-factor authentication inside SideStore. VexSign does not request your Apple password, session, certificates or pairing secrets."))
                Button(.localized("Open SideStore for account setup")) { open("sidestore://") }
                    .disabled(!sideStoreAvailable)
                Text(sideStoreAvailable ? .localized("SideStore URL handler detected") : .localized("SideStore URL handler not detected"))
                    .font(.caption).foregroundStyle(.secondary)
                Link(.localized("SideStore setup guide"), destination: URL(string: "https://docs.sidestore.io/")!)
            } header: { Text(.localized("1. Account & renewal")) } footer: {
                Text(.localized("Install SideStore using its official instructions. Configure its supported VPN/pairing and refresh automation there. VexSign cannot read your SideStore account or guarantee background renewal."))
            }

            Section {
                TextField(.localized("Hosted IPA HTTPS URL"), text: $hostedIPA)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let issue = CompanionHandoffLink.issue(for: hostedIPA) {
                    Label(issue.message, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let host = CompanionHandoffLink.destinationHost(for: hostedIPA) {
                    LabeledContent(.localized("Destination host"), value: host)
                        .font(.caption)
                }
                if !sideStoreAvailable {
                    Text(.localized("Install or open SideStore, then return here to refresh detection."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(.localized("Send hosted IPA to SideStore")) { confirmHandoff = true }
                    .disabled(!sideStoreAvailable || installLink == nil)
            } header: { Text(.localized("2. Install or refresh the container")) } footer: {
                Text(.localized("Use a trusted LiveContainer IPA URL or another IPA you intend to install. SideStore performs authentication, signing and installation. Sending a link is not proof of success; verify the result in SideStore. Only apps managed by SideStore can be renewed by it."))
            }

            }

            Section {
                if let libraryApp {
                    Text(libraryApp.base.name ?? .localized("Application")).font(.headline)
                    Button {
                        prepareLibraryIPA(libraryApp)
                    } label: {
                        HStack {
                            Label(.localized("Prepare library IPA for sharing"), systemImage: "archivebox")
                            if preparingLibraryIPA { ProgressView() }
                        }
                    }
                    .disabled(preparingIPA)
                    if preparingLibraryIPA {
                        ProgressView(value: min(max(archiveStatus.packageProgress, 0), 1)) {
                            Text(.localized("Preparing IPA — copying and archiving"))
                        }
                    }
                    Text(.localized("Exports the stored library bundle as-is. It does not re-sign, install or upload the app. LiveContainer decides whether the guest is compatible."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(.localized("Choose IPA to share")) { showImporter = true }
                    .disabled(preparingIPA)
                if stagingFileIPA {
                    ProgressView(.localized("Copying IPA for sharing…"))
                    Button(.localized("Cancel file preparation"), role: .cancel) {
                        stagingCopyTask?.cancel()
                    }
                }
                if let sharedIPA {
                    if embedded {
                        EmbeddedContainerImportButton(ipa: sharedIPA, staging: $preparingEmbeddedIPA)
                            .disabled(preparingIPA || !integrity.allowsSharing)
                    }
                    ShareLink(item: sharedIPA) {
                        Label(.localized("Share IPA to companion app"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(preparingIPA || !integrity.allowsSharing)
                    Text(sharedIPA.lastPathComponent).font(.caption).lineLimit(2)
                    if let size = stagedFileSize(sharedIPA) {
                        LabeledContent(.localized("Prepared file size"), value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                    }
                    if let ipaFingerprint {
                        Text(.localized("SHA-256 fingerprint")).font(.caption.bold())
                        Text(ipaFingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        ShareLink(item: ipaFingerprint) {
                            Label(.localized("Share fingerprint"), systemImage: "number")
                        }
                        .disabled(preparingIPA)
                    } else {
                        Button {
                            calculateFingerprint(sharedIPA)
                        } label: {
                            HStack {
                                Text(.localized("Calculate SHA-256"))
                                if hashingIPA { ProgressView() }
                            }
                        }
                        .disabled(preparingIPA)
                    }
                    TextField(.localized("Publisher SHA-256 (optional)"), text: $expectedFingerprint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .disabled(preparingIPA)
                    Label(integrity.message, systemImage: integrity == .mismatch ? "exclamationmark.shield" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(integrity == .mismatch ? Color.orange : Color.secondary)
                    Text(.localized("A fingerprint identifies these file bytes; it does not prove publisher identity, signing validity or companion compatibility."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(.localized("Remove staged IPA"), role: .destructive) {
                        do {
                            try FileManager.default.removeItem(at: sharedIPA.deletingLastPathComponent())
                            self.sharedIPA = nil
                            ipaFingerprint = nil
                            expectedFingerprint = ""
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(preparingIPA)
                }
                if !EmbeddedContainerRuntime.isGuestBuild {
                Button(.localized("Open LiveContainer")) { open("livecontainer://") }
                    .disabled(!liveContainerAvailable)
                Text(liveContainerAvailable ? .localized("LiveContainer URL handler detected") : .localized("LiveContainer URL handler not detected"))
                    .font(.caption).foregroundStyle(.secondary)
                }
                Link(.localized("LiveContainer project & instructions"), destination: URL(string: "https://github.com/LiveContainer/LiveContainer")!)
            } header: { Text(.localized("3. Import guest apps")) } footer: {
                Text(embedded
                     ? .localized("Use the prepared import button to copy the checked IPA directly into the embedded host inbox, then confirm import in LiveContainer. Host signing and JIT requirements still apply. A staged file is not a verified installation.")
                     : .localized("Choose SideStore to install an IPA, or LiveContainer to import a guest, if offered in the system share sheet. Otherwise save to Files and import inside the target app. Signing, JIT and execution requirements belong to the receiving app. Sharing does not confirm installation or import."))
            }
            Section {
                NavigationLink(destination: JITSettingsView()) {
                    Label(.localized("JIT & On-Device Pairing"), systemImage: "bolt.badge.automatic.fill")
                }
            } footer: {
                Text(.localized("VexSign certificate-based automation is separate from SideStore renewal. Neither app shares Apple-account credentials through this workflow."))
            }
        }
        .toolbar {
            if libraryApp != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(.localized("Close")) { dismiss() }
                        .disabled(preparingIPA)
                }
            }
        }
        .onReceive(archiveStatus.$packageProgress) { progress in
            if let exportTask, preparingLibraryIPA {
                UnifiedTaskCenter.shared.update(exportTask, progress: progress)
            }
        }
        .interactiveDismissDisabled(preparingIPA)
        .onAppear(perform: refreshAvailability)
        .nbOnChange(of: scenePhase) { phase in if phase == .active { refreshAvailability() } }
        .confirmationDialog(.localized("Send this IPA URL to SideStore?"), isPresented: $confirmHandoff, titleVisibility: .visible) {
            Button(.localized("Continue in SideStore")) {
                if let link = installLink { open(link.absoluteString) }
            }
            Button(.localized("Cancel"), role: .cancel) {}
        } message: {
            Text([
                CompanionHandoffLink.destinationHost(for: hostedIPA) ?? "",
                .localized("SideStore will receive the complete URL, including any query tokens. Use only a trusted IPA host. VexSign cannot confirm download, signing or installation there.")
            ].joined(separator: "\n\n"))
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { result in
            do {
                let url = try result.get()
                guard url.pathExtension.lowercased() == "ipa" else {
                    errorMessage = .localized("Choose an IPA file, not a certificate or provisioning profile.")
                    return
                }
                stageSelectedIPA(url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert(.localized("Companion handoff failed"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(.localized("OK"), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func stagedFileSize(_ url: URL) -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value
        } catch {
            return nil
        }
    }

    private func calculateFingerprint(_ url: URL) {
        guard !preparingIPA, sharedIPA == url else { return }
        hashingIPA = true
        Task {
            defer { hashingIPA = false }
            let fingerprint = await Task.detached(priority: .utility) {
                FileIntegrity.sha256(of: url)
            }.value
            guard sharedIPA == url else { return }
            if let fingerprint {
                ipaFingerprint = fingerprint
            } else {
                errorMessage = .localized("The prepared IPA could not be read. Prepare or select the file again.")
            }
        }
    }

    private func stageSelectedIPA(_ source: URL) {
        guard !preparingIPA else { return }
        stagingFileIPA = true
        // Retain file-provider access until the asynchronous copy has finished.
        let scoped = source.startAccessingSecurityScopedResource()
        let record = UnifiedTaskCenter.shared.begin(
            kind: .export, title: source.lastPathComponent,
            subtitle: .localized("Copying IPA for sharing…"), phase: .queued
        )
        Task {
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
                stagingFileIPA = false
                stagingCopyTask = nil
            }
            do {
                let operation = Task.detached(priority: .userInitiated) {
                    try CompanionIPAStager.copy(source)
                }
                stagingCopyTask = operation
                let copy = try await operation.value
                removePreviousStagingCopy()
                ipaFingerprint = nil
                expectedFingerprint = ""
                sharedIPA = copy
                UnifiedTaskCenter.shared.transition(record, to: .completed)
            } catch is CancellationError {
                UnifiedTaskCenter.shared.transition(record, to: .cancelled)
            } catch {
                UnifiedTaskCenter.shared.transition(record, to: .failed, error: error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removePreviousStagingCopy() {
        guard let previous = sharedIPA else { return }
        do {
            try FileManager.default.removeItem(at: previous.deletingLastPathComponent())
        } catch {
            FileLogger.log("Could not remove previous companion handoff: \(error)", category: "update")
        }
    }

    private func prepareLibraryIPA(_ target: AnyApp) {
        guard !preparingIPA else { return }
        preparingLibraryIPA = true
        archiveStatus.packageProgress = 0
        let status = archiveStatus
        let record = UnifiedTaskCenter.shared.begin(
            kind: .export,
            title: target.base.name ?? .localized("Application"),
            subtitle: .localized("Preparing companion IPA"),
            phase: .queued
        )
        exportTask = record
        Task {
            defer { preparingLibraryIPA = false }
            do {
                let package = try await Task.detached(priority: .userInitiated) {
                    let handler = ArchiveHandler(app: target.base, viewModel: status)
                    return try await handler.prepareCompanionArchive()
                }.value
                removePreviousStagingCopy()
                ipaFingerprint = nil
                expectedFingerprint = ""
                sharedIPA = package
                UnifiedTaskCenter.shared.transition(record, to: .completed)
            } catch {
                UnifiedTaskCenter.shared.transition(record, to: .failed, error: error.localizedDescription)
                errorMessage = error.localizedDescription
            }
            exportTask = nil
        }
    }

    private func refreshAvailability() {
        sideStoreAvailable = UIApplication.shared.canOpenURL(URL(string: "sidestore://")!)
        liveContainerAvailable = UIApplication.shared.canOpenURL(URL(string: "livecontainer://")!)
    }

    private func open(_ value: String) {
        guard let url = URL(string: value) else { return }
        requestOpened = false
        UIApplication.shared.open(url, options: [:]) { success in
            if success { requestOpened = true }
            if !success { errorMessage = .localized("The companion app could not open this request. Check that it is installed and supports this action.") }
        }
    }
}
