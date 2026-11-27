// MARK: - Device lifecycle workspace
//
// The UI only renders facts supplied by the lifecycle model. Actions that need a device are
// shown with the transport they require, and destructive actions ask for the exact bundle id.

import SwiftUI
import UniformTypeIdentifiers
import NimbleExtensions

struct DeviceLifecycleWorkspaceView: View {
    @EnvironmentObject private var app: AppContainer
    @StateObject private var model: DeviceLifecycleWorkspaceModel
    @State private var showsBackupImporter = false
    @State private var showsContainerImporter = false
    @State private var archivePassword = ""
    @State private var removalTarget: LibraryAppRecord?
    @State private var typedBundleIdentifier = ""
    @State private var confirmsForget = false
    @State private var confirmsRestore = false

    init(model: DeviceLifecycleWorkspaceModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Form {
            limitationSection
            devicesSection
            if let device = model.selectedDevice { deviceDetailSection(device) }
            inventorySection
            librarySection
            updateSection
            backupSection
            resultsSection
        }
        .navigationTitle(.localized("Device & app lifecycle"))
        .dismissableKeyboard()
        .toolbar { toolbar }
        .alert(.localized("Error"), isPresented: Binding(
            get: { model.message != nil && model.message?.isEmpty == false },
            set: { if !$0 { model.message = nil } }
        )) {
            Button(.localized("OK"), role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
        .fileImporter(isPresented: $showsBackupImporter, allowedContentTypes: [.data, .archive]) { result in
            if case .success(let url) = result { model.previewBackup(file: url, password: archivePassword) }
        }
        .fileImporter(isPresented: $showsContainerImporter, allowedContentTypes: [.data, .archive]) { result in
            if case .success(let url) = result {
                model.previewContainer(file: url, password: archivePassword.isEmpty ? nil : archivePassword)
            }
        }
        .confirmationDialog(
            String.localized("Remove from device?"), isPresented: Binding(
                get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } }
            ), titleVisibility: .visible
        ) {
            Button(.localized("Request removal"), role: .destructive) {
                if let target = removalTarget { model.remove(app: target, typedBundleIdentifier: typedBundleIdentifier) }
                typedBundleIdentifier = ""
            }
            Button(.localized("Cancel"), role: .cancel) { typedBundleIdentifier = "" }
        } message: {
            TextField(.localized("Bundle identifier"), text: $typedBundleIdentifier)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text(.localized("Type the exact bundle identifier to confirm. Removal deletes app data from the device and cannot be undone. The Library copy is kept."))
        }
        .task { await model.load() }
    }

    private var limitationSection: some View {
        Section {
            Text(.localized("VexSign uses the reviewed pairing transport and CoreDevice app service. A pairing file is not a live connection, a successful list is not a full device-wide inventory, and an acknowledged install is not proof the app launched. Simulator builds cannot pair."))
                .font(.footnote)
        }
    }

    private var devicesSection: some View {
        Section {
            if model.devices.isEmpty {
                Text(.localized("No device records yet. Open Tunnel & Pairing to review a pairing record, then refresh this screen."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.devices) { device in
                Button {
                    model.selectedDeviceID = device.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.displayName).font(.subheadline.weight(.semibold))
                            Text(device.subtitle).font(.caption2).foregroundStyle(.secondary)
                            Text("\(device.link.title) · \(device.trust.title)")
                                .font(.caption2).foregroundStyle(color(for: device.link))
                        }
                        Spacer()
                        if model.selectedDeviceID == device.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                .accessibilityLabel(.localized("Selected"))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("device.row.\(device.logSafeIdentifier)")
            }
        } header: {
            Text(.localized("Devices"))
        }
    }

    private func deviceDetailSection(_ device: ManagedDeviceRecord) -> some View {
        Section {
            LabeledContent(.localized("Identifier")) {
                Text(device.logSafeIdentifier).monospaced().textSelection(.enabled)
            }
            LabeledContent(.localized("Connection"), value: device.link.title)
            LabeledContent(.localized("Pairing"), value: device.pairing.title)
            LabeledContent(.localized("Trust"), value: device.trust.title)
            if let last = device.lastConnectedAt { LabeledContent(.localized("Last connection"), value: Self.timeFormatter.string(from: last)) }
            if let last = model.syncState?.lastSuccessfulSyncAt { LabeledContent(.localized("Last successful sync"), value: Self.timeFormatter.string(from: last)) }
            Text(device.link.detail).font(.caption2).foregroundStyle(.secondary)

            ForEach(device.capabilities) { capability in
                HStack(alignment: .firstTextBaseline) {
                    Text(capability.title).font(.caption)
                    Spacer()
                    Text(capability.statusTitle).font(.caption2)
                        .foregroundStyle(capability.isSupported ? .green : .secondary)
                }
            }
            ForEach(device.diagnostics) { diagnostic in
                VStack(alignment: .leading, spacing: 2) {
                    Text(diagnostic.code).font(.caption2.weight(.semibold))
                    Text(diagnostic.message).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button(role: .destructive) { confirmsForget = true } label: {
                Label(.localized("Forget this device record"), systemImage: "trash")
            }
            .confirmationDialog(String.localized("Forget this device?"), isPresented: $confirmsForget,
                                titleVisibility: .visible) {
                Button(.localized("Forget locally"), role: .destructive) { model.forgetSelectedDevice() }
                Button(.localized("Cancel"), role: .cancel) {}
            } message: {
                Text(.localized("Only the local record and its cached inventory are deleted. Pairing on the device is unchanged."))
            }
        } header: {
            Text(.localized("Selected device"))
        }
    }

    private var inventorySection: some View {
        Section {
            if let snapshot = model.snapshot {
                LabeledContent(.localized("Captured"), value: Self.timeFormatter.string(from: snapshot.capturedAt))
                LabeledContent(.localized("Freshness"), value: snapshot.freshnessTitle)
                LabeledContent(.localized("Reported apps"), value: "\(snapshot.applications.count)")
                ForEach(snapshot.applications) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.subheadline)
                        Text(app.bundleIdentifier).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(String.localized("Version %@ · build %@", arguments: app.version ?? "?", app.build ?? "?"))
                            .font(.caption2)
                    }
                }
            } else {
                Text(.localized("No device inventory has been read yet. A missing report never means an app is absent."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reconciliation = model.reconciliation {
                Text(reconciliation.summary).font(.caption2).foregroundStyle(.secondary)
                ForEach(reconciliation.changes) { change in
                    HStack {
                        Text(change.bundleIdentifier).font(.caption2.monospaced())
                        Spacer()
                        Text(change.title).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(.localized("Installed-app inventory"))
        } footer: {
            Text(.localized("Only positive, identity-bound app-service records are stored. Omission may be a filtered response, not a removal."))
                .font(.caption2)
        }
    }

    private var librarySection: some View {
        Section {
            if let comparison = model.libraryComparison {
                Text(comparison.summary).font(.caption)
                ForEach(comparison.matches) { match in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(match.libraryName).font(.subheadline)
                            Spacer()
                            Text(match.title).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(match.bundleIdentifier).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(String.localized("Library %@ · device %@", arguments:
                            match.libraryVersion ?? "?", match.deviceVersion ?? "?"))
                            .font(.caption2)
                        if let app = libraryApp(matching: match.bundleIdentifier) {
                            lifecycleButtons(for: app, match: match)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text(.localized("Synchronize to compare the device with the Library."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(.localized("Library reconciliation"))
        }
    }

    private func lifecycleButtons(for app: LibraryAppRecord, match: DeviceLibraryMatch) -> some View {
        HStack(spacing: 8) {
            Button(.localized("Install")) { model.submit(app: app, action: .install) }
                .disabled(model.isBusy || match.state == .duplicateIdentifier)
            if match.state != .noDeviceReport {
                Button(.localized("Reinstall")) { model.submit(app: app, action: .reinstall) }
                    .disabled(model.isBusy)
            }
            Button(role: .destructive) {
                removalTarget = app
                typedBundleIdentifier = ""
            } label: {
                Text(.localized("Remove…"))
            }
            .disabled(model.isBusy || model.selectedDevice?.supportsRemoval != true)
        }
        .font(.caption)
    }

    private var updateSection: some View {
        Section {
            if model.updatePlans.isEmpty {
                Text(.localized("No catalog updates were matched to this device inventory."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.updatePlans) { plan in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(plan.bundleIdentifier).font(.subheadline)
                        Spacer()
                        Text(plan.title).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(String.localized("%@ → %@ from %@", arguments:
                        plan.installedVersion ?? "?", plan.candidateVersion, plan.sourceName))
                        .font(.caption2)
                    Text(plan.reason).font(.caption2).foregroundStyle(.secondary)
                    if plan.verdict == .updateAvailable,
                       let app = libraryApp(matching: plan.bundleIdentifier) {
                        HStack(spacing: 8) {
                            Button(.localized("Download update")) { model.downloadUpdate(plan) }
                            Button(.localized("Install library copy")) { model.submit(app: app, action: .update) }
                        }
                        .font(.caption)
                        .disabled(model.isBusy)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(.localized("Catalog updates"))
        }
    }

    private var backupSection: some View {
        Section {
            Toggle(.localized("Library records and metadata"), isOn: $model.backupScope.includeLibraryMetadata)
            Toggle(.localized("Sources"), isOn: $model.backupScope.includeSources)
            Toggle(.localized("Settings"), isOn: $model.backupScope.includeSettings)
            Toggle(.localized("Tweaks"), isOn: $model.backupScope.includeTweaks)
            Toggle(.localized("Certificates (encrypted)"), isOn: $model.backupScope.includeCertificates)
            SecureField(.localized("Backup password"), text: $model.backupScope.password)
            Text(model.backupScope.summary).font(.caption2).foregroundStyle(.secondary)
            Button { model.makeBackup() } label: {
                Label(.localized("Create VexSign data backup"), systemImage: "externaldrive.badge.plus")
            }
            .disabled(model.isBusy)

            Button { showsBackupImporter = true } label: {
                Label(.localized("Verify a backup file"), systemImage: "doc.badge.ellipsis")
            }
            Button { showsContainerImporter = true } label: {
                Label(.localized("Verify a container export"), systemImage: "shippingbox")
            }
            if let preview = model.backupPreview {
                LabeledContent(.localized("Archive"), value: String(preview.integrity.packSHA256.prefix(12)) + "…")
                Button(role: .destructive) { confirmsRestore = true } label: {
                    Text(.localized("Restore verified archive…"))
                }
                .confirmationDialog(String.localized("Restore VexSign data?"), isPresented: $confirmsRestore,
                                    titleVisibility: .visible) {
                    Button(.localized("Restore"), role: .destructive) {
                        model.restoreBackup(archiveID: preview.id, components: preview.contents)
                    }
                    Button(.localized("Cancel"), role: .cancel) {}
                } message: {
                    Text(.localized("Existing records are retained. Only missing entries are restored by the backup engine."))
                }
                ForEach(model.restoreConflicts) { conflict in
                    Text("\(conflict.bundleIdentifier): \(conflict.detail)").font(.caption2)
                }
            }
            if let preview = model.containerPreview {
                LabeledContent(String.localized("Container"), value: preview.container.displayName)
                LabeledContent(.localized("Format"), value: preview.format)
            }
            ForEach(model.backupScope.exclusions) { exclusion in
                Text("\(exclusion.reason.rawValue): \(exclusion.detail)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text(.localized("Backup and restore boundaries"))
        } footer: {
            Text(.localized("This backs up VexSign records and VexSign-managed containers. It cannot back up another app's sandbox, keychain or complete iOS device data."))
                .font(.caption2)
        }
    }

    private var resultsSection: some View {
        Section {
            if model.results.isEmpty {
                Text(.localized("No lifecycle operations have been run in this session."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.results) { result in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(result.action.rawValue).font(.caption.weight(.semibold))
                        Spacer()
                        Text(result.outcome.title).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(result.bundleIdentifier).font(.caption2.monospaced())
                    Text(result.message).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(.localized("Operation history"))
        } footer: {
            NavigationLink(destination: TaskCenterView(ownsNavigationStack: false)) {
                Label(.localized("Open the shared task center"), systemImage: "checklist")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if model.isBusy {
                Button(.localized("Cancel"), role: .cancel) { model.cancel() }
            } else {
                Menu {
                    Button { Task { await model.load() } } label: {
                        Label(.localized("Refresh devices"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button { model.verifySelected() } label: {
                        Label(.localized("Verify device"), systemImage: "lock.shield")
                    }
                    Button { model.refreshInventory() } label: {
                        Label(.localized("Refresh inventory"), systemImage: "list.bullet.rectangle")
                    }
                    Button { model.synchronizeSelected() } label: {
                        Label(.localized("Synchronize"), systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel(.localized("Device actions"))
                }
                .disabled(model.selectedDeviceID == nil)
            }
        }
    }

    private func libraryApp(matching identifier: String) -> LibraryAppRecord? {
        app.workspace.snapshot.apps.first { $0.identifier?.lowercased() == identifier.lowercased() }
    }

    private func color(for link: ManagedDeviceLink) -> Color {
        switch link {
        case .connected: .green
        case .paired, .remembered: .blue
        case .unavailable: .secondary
        case .pairingRequired, .untrusted: .orange
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
