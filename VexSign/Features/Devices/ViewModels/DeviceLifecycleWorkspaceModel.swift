// MARK: - Device lifecycle presentation state
//
// Views bind to this model only. It never opens a device session, reads a database directly,
// or moves a task: those owners stay behind the injected services.

import Foundation
import Combine
import IDeviceSwift
import NimbleExtensions

@MainActor
final class DeviceLifecycleWorkspaceModel: ObservableObject {
    @Published private(set) var devices: [ManagedDeviceRecord] = []
    @Published var selectedDeviceID: String? {
        didSet { if oldValue != selectedDeviceID { Task { await loadDeviceDetail() } } }
    }
    @Published private(set) var snapshot: DeviceInventorySnapshot?
    @Published private(set) var syncState: DeviceSyncState?
    @Published private(set) var reconciliation: DeviceInventoryReconciliation?
    @Published private(set) var libraryComparison: DeviceLibraryComparison?
    @Published private(set) var updatePlans: [DeviceUpdatePlan] = []
    @Published private(set) var results: [DeviceLifecycleResult] = []
    @Published private(set) var backupPreview: BackupArchiveSnapshot?
    @Published private(set) var containerPreview: ContainerExportManifest?
    @Published private(set) var restoreConflicts: [DeviceRestoreConflict] = []
    @Published private(set) var isWorking = false
    @Published private(set) var stage: String?
    @Published var message: String?
    @Published var backupScope = DeviceBackupScope()

    private let registry: DeviceRegistryService
    private let inventory: DeviceInventoryService
    private let coordinator: DeviceLifecycleCoordinator
    private let downloader: any DeviceUpdateDownloading
    private let backups: DeviceBackupCoordinator
    private let libraryAppsProvider: @MainActor () -> [LibraryAppRecord]
    private let catalogAppsProvider: @MainActor () async -> [CatalogAppRecord]
    private let signingIdentityProvider: @MainActor () -> Bool
    private let availableBytesProvider: @MainActor () -> Int64?
    private let certificateExpiryProvider: @MainActor (LibraryAppReference) -> Date?
    private let diagnosticRecorder: DiagnosticRecorder
    private var operation: Task<Void, Never>?
    /// Retired when Cancel runs. A suspended worker can still deliver a result or an
    /// error after cancellation; generation checks stop it from overwriting the new state.
    private var operationGeneration = UUID()

    init(
        registry: DeviceRegistryService,
        inventory: DeviceInventoryService,
        coordinator: DeviceLifecycleCoordinator,
        downloader: any DeviceUpdateDownloading,
        backups: DeviceBackupCoordinator,
        libraryAppsProvider: @escaping @MainActor () -> [LibraryAppRecord],
        catalogAppsProvider: @escaping @MainActor () async -> [CatalogAppRecord],
        signingIdentityProvider: @escaping @MainActor () -> Bool,
        availableBytesProvider: @escaping @MainActor () -> Int64?,
        certificateExpiryProvider: @escaping @MainActor (LibraryAppReference) -> Date? = { _ in nil },
        diagnosticRecorder: DiagnosticRecorder = .fileRecorder
    ) {
        self.registry = registry
        self.inventory = inventory
        self.coordinator = coordinator
        self.downloader = downloader
        self.backups = backups
        self.libraryAppsProvider = libraryAppsProvider
        self.catalogAppsProvider = catalogAppsProvider
        self.signingIdentityProvider = signingIdentityProvider
        self.availableBytesProvider = availableBytesProvider
        self.certificateExpiryProvider = certificateExpiryProvider
        self.diagnosticRecorder = diagnosticRecorder
    }

    var selectedDevice: ManagedDeviceRecord? {
        devices.first { $0.id == selectedDeviceID }
    }

    var isBusy: Bool { isWorking || operation != nil }

    // MARK: Loading

    func load() async {
        guard !isBusy else { return }
        stage = .localized("Reading remembered devices…")
        isWorking = true
        defer { isWorking = false; stage = nil }
        await reloadDevices()
    }

    private func reloadDevices() async {
        do {
            var records = try await registry.refreshFromPairingRecord()
            records.sort { $0.updatedAt > $1.updatedAt }
            devices = records
            if selectedDeviceID == nil || !records.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = records.first?.id
            }
            await loadDeviceDetail()
            message = .localized("Device rows come from the reviewed pairing record and previously confirmed observations. A row is never marked connected without a fresh device answer.")
        } catch {
            do { devices = try await registry.devices() }
            catch { devices = [] }
            message = error.localizedDescription
        }
    }

    func loadDeviceDetail() async {
        guard let deviceID = selectedDeviceID else {
            snapshot = nil; syncState = nil; reconciliation = nil; libraryComparison = nil; updatePlans = []
            return
        }
        do {
            snapshot = try await inventory.latestSnapshot(deviceID: deviceID)
            syncState = try await inventory.syncState(deviceID: deviceID)
            libraryComparison = DeviceLibraryReconciler.compare(
                libraryApps: libraryAppsProvider(), snapshot: snapshot
            )
            await rebuildUpdatePlans()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Connection and inventory

    func verifySelected() {
        guard let deviceID = selectedDeviceID else { return }
        run(title: .localized("Verifying the selected device…"), operationType: "device-verify") {
            try await self.registry.verify(deviceID: deviceID)
            try await self.reloadDevices()
            self.message = .localized("The device answered a fresh identity query. Any install or inventory operation still needs its own consented session.")
        }
    }

    func refreshInventory() {
        guard let deviceID = selectedDeviceID else { return }
        run(title: .localized("Reading device inventory…"), operationType: "inventory") {
            let apps = self.libraryAppsProvider()
            let reconciliation = try await self.inventory.refresh(
                deviceID: deviceID,
                wantedBundleIdentifiers: apps.compactMap { $0.identifier }.filter {
                    DeviceApplicationInventory.isBundleIdentifier($0)
                }
            )
            self.reconciliation = reconciliation
            try await self.loadDeviceDetail()
            self.message = reconciliation.summary
        }
    }

    /// One user-visible synchronization: verify, read a fresh inventory, compare with the
    /// library, and record success only when all three completed.
    func synchronizeSelected() {
        guard let deviceID = selectedDeviceID else { return }
        run(title: .localized("Synchronizing device and Library…"), operationType: "sync") {
            if self.selectedDevice?.link.isConnected != true {
                _ = try await self.registry.verify(deviceID: deviceID)
            }
            let apps = self.libraryAppsProvider()
            self.reconciliation = try await self.inventory.refresh(
                deviceID: deviceID,
                wantedBundleIdentifiers: apps.compactMap { $0.identifier }.filter {
                    DeviceApplicationInventory.isBundleIdentifier($0)
                }
            )
            try await self.reloadDevices()
            let comparison = self.libraryComparison?.summary ?? .localized("No library comparison was available.")
            self.message = String.localized("Synchronization completed: %@", arguments: comparison)
        }
    }

    func cancel() {
        operation?.cancel()
        // Retire the callback generation and let the worker's own `defer` retire the
        // task. Clearing `operation` or `isWorking` here would open a second operation
        // while the cancelled worker is still unwinding and could publish stale state.
        operationGeneration = UUID()
        stage = nil
        message = .localized("The operation was cancelled. Check the device before retrying.")
    }

    // MARK: Application lifecycle

    func submit(app: LibraryAppRecord, action: DeviceLifecycleAction) {
        guard let deviceID = selectedDeviceID else { return }
        guard let bundle = app.identifier, DeviceApplicationInventory.isBundleIdentifier(bundle) else {
            message = .localized("This library app has no usable bundle identifier.")
            return
        }
        let reference = LibraryAppReference(recordID: app.id, uuid: app.uuid ?? app.id, isSigned: app.isSigned)
        let target = DeviceLifecycleTarget(
            deviceID: deviceID, reference: reference, bundleIdentifier: bundle,
            version: app.version ?? "", build: nil,
            certificateExpiry: certificateExpiryProvider(reference)
        )
        run(title: .localized("Submitting the selected signed app…"), operationType: "install") {
            let result = try await self.coordinator.install(target, action: action)
            self.results.insert(result, at: 0)
            try await self.loadDeviceDetail()
            self.message = result.message
        }
    }

    func remove(app: LibraryAppRecord, typedBundleIdentifier: String) {
        guard let deviceID = selectedDeviceID else { return }
        guard let bundle = app.identifier, typedBundleIdentifier == bundle else {
            message = .localized("Type the exact bundle identifier to confirm removal.")
            return
        }
        let reference = LibraryAppReference(recordID: app.id, uuid: app.uuid ?? app.id, isSigned: app.isSigned)
        let target = DeviceLifecycleTarget(deviceID: deviceID, reference: reference,
                                           bundleIdentifier: bundle, version: app.version ?? "",
                                           authorizedRemoval: true)
        run(title: .localized("Requesting app removal…"), operationType: "removal") {
            let result = try await self.coordinator.remove(target)
            self.results.insert(result, at: 0)
            try await self.loadDeviceDetail()
            self.message = result.message
        }
    }

    func forgetSelectedDevice() {
        guard let deviceID = selectedDeviceID else { return }
        run(title: .localized("Forgetting the device record…")) {
            try await self.registry.forget(deviceID: deviceID)
            self.selectedDeviceID = nil
            try await self.reloadDevices()
            self.message = .localized("The remembered record and its inventory history were deleted locally. This does not unpair the device or delete anything from it.")
        }
    }

    // MARK: Updates

    func rebuildUpdatePlans() async {
        guard let device = selectedDevice else { updatePlans = []; return }
        let context = DeviceUpdateContext(
            installedApplications: snapshot?.applications ?? [],
            catalogApps: await catalogAppsProvider(),
            deviceOSVersion: device.osVersion,
            capabilities: device.capabilities,
            signingIdentityAvailable: signingIdentityProvider(),
            authorizationExpiresAt: nil,
            availableBytes: availableBytesProvider(),
            catalogIntegrityVerified: false
        )
        updatePlans = DeviceUpdatePlanner.plans(context)
    }

    func downloadUpdate(_ plan: DeviceUpdatePlan) {
        guard let request = plan.download, plan.canDownload else {
            message = plan.reason
            return
        }
        if downloader.start(request) {
            message = .localized("The update was handed to VexSign's download manager. Integrity verification and signing still have to finish before installation.")
        } else {
            message = .localized("The download manager refused this update request. Check the release URL and retry.")
        }
    }

    // MARK: Backup and restore

    func makeBackup() {
        run(title: .localized("Backing up VexSign data…"), recordsDeviceFailure: false) {
            let result = try await self.backups.makeBackup(scope: self.backupScope)
            self.message = result.message
        }
    }

    func previewBackup(file: URL, password: String) {
        run(title: .localized("Verifying the backup…"), recordsDeviceFailure: false) {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let archive = try await self.backups.preview(file: file, password: password)
            self.backupPreview = archive
            let existing = Set(self.libraryAppsProvider().compactMap { $0.identifier }.map { $0.lowercased() })
            self.restoreConflicts = self.backups.conflicts(archive: archive, existingBundleIdentifiers: existing)
            self.message = .localized("The archive was opened and verified. Existing library records are kept on restore; review the conflicts below.")
        }
    }

    func previewContainer(file: URL, password: String?) {
        run(title: .localized("Verifying the container archive…"), recordsDeviceFailure: false) {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let manifest = try await self.backups.previewContainer(file: file, password: password)
            self.containerPreview = manifest
            self.message = .localized("The VexSign container manifest passed format validation. Restoring it does not read any third-party app sandbox.")
        }
    }

    func restoreBackup(archiveID: UUID, components: BackupComponents) {
        run(title: .localized("Restoring VexSign data…"), recordsDeviceFailure: false) {
            _ = try await self.backups.restore(archiveID: archiveID, components: components)
            self.backupPreview = nil
            self.restoreConflicts = []
            try await self.loadDeviceDetail()
            self.message = .localized("The verified archive was restored through the existing backup engine. Existing records were not silently overwritten.")
        }
    }

    func restoreContainer(file: URL, password: String?, replaceContainerID: String?) {
        run(title: .localized("Restoring the VexSign container…"), recordsDeviceFailure: false) {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let authorization: ContainerRestoreAuthorization
            if let id = replaceContainerID { authorization = .replace(id: id) }
            else { authorization = .createNew }
            _ = try await self.backups.restoreContainer(file: file, password: password,
                                                        authorization: authorization)
            self.message = .localized("The container was restored after archive validation. It remains VexSign-owned storage, not an iOS application sandbox.")
        }
    }

    // MARK: Helpers

    private func run(title: String, operationType: String = "device",
                     recordsDeviceFailure: Bool = true,
                     work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        let generation = UUID()
        let startedAt = Date()
        operationGeneration = generation
        isWorking = true
        stage = title
        message = nil
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // A cancelled generation is already retired by `cancel()`; do not let
                // this old worker clear the state of whatever replaced it.
                if self.operationGeneration == generation {
                    self.operation = nil
                    self.isWorking = false
                    self.stage = nil
                }
            }
            do {
                try Task.checkCancellation()
                try await work()
            } catch is CancellationError {
                guard self.operationGeneration == generation else { return }
                self.message = .localized("The operation was cancelled. Check the device before retrying.")
                return
            } catch {
                guard self.operationGeneration == generation else { return }
                self.message = error.localizedDescription
                let classified = ErrorBoundary.classify(error)
                await self.diagnosticRecorder.record(.deviceFailure(
                    operationID: generation.uuidString,
                    operationType: operationType,
                    connectionState: self.selectedDevice?.link.rawValue ?? "unknown",
                    failureCategory: classified.code.rawValue,
                    systemErrorCode: nil,
                    durationMs: Int(max(0, Date().timeIntervalSince(startedAt) * 1000)),
                    recoveryOutcome: DiagnosticRecoveryGuide.suggestion(for: classified.code),
                    deviceModel: self.selectedDevice?.productType,
                    osVersion: self.selectedDevice?.osVersion,
                    userMessage: self.message ?? .localized("The device operation failed.")
                ))
                if recordsDeviceFailure, let deviceID = self.selectedDeviceID {
                    do { try await self.registry.recordFailure(deviceID: deviceID, error: error) }
                    catch { /* The presented error is the original operation failure. */ }
                }
            }
        }
    }
}
