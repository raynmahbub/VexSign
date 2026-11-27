// MARK: - Full device inventory refresh
//
// The paired CoreDevice installation service can return a list of positive app records. Only
// those records are persisted. An empty or unreadable response is retained as unknown, never
// converted into "no apps installed". Every reading must carry the same frozen device/record
// binding that the consented request produced.

import Foundation
import IDeviceSwift
import NimbleExtensions

protocol DeviceApplicationInventoryQuerying: Sendable {
    func inventory(
        request: DeviceConnectionRequest,
        reporting: @escaping @Sendable (DeviceConnectionStage) -> Void
    ) async throws -> DeviceApplicationInventory
}

struct PairedDeviceApplicationInventoryQuery: DeviceApplicationInventoryQuerying {
    func inventory(
        request: DeviceConnectionRequest,
        reporting: @escaping @Sendable (DeviceConnectionStage) -> Void
    ) async throws -> DeviceApplicationInventory {
        try await HeartbeatManager.shared.queryApplicationInventory(request: request, reporting: reporting)
    }
}

@MainActor
final class DeviceInventoryService {
    private let store: DeviceLifecycleStore
    private let query: any DeviceApplicationInventoryQuerying
    private let requestProvider: @MainActor () async throws -> DeviceConnectionRequest
    private let reporter: DeviceLifecycleTaskReporter

    init(
        store: DeviceLifecycleStore,
        query: any DeviceApplicationInventoryQuerying = PairedDeviceApplicationInventoryQuery(),
        requestProvider: @escaping @MainActor () async throws -> DeviceConnectionRequest = {
            try await PairingBridge.installationRequest()
        },
        reporter: DeviceLifecycleTaskReporter
    ) {
        self.store = store
        self.query = query
        self.requestProvider = requestProvider
        self.reporter = reporter
    }

    /// Returns only after the snapshot and the sync marker were both committed. Progress is
    /// indeterminate: the service reports protocol stages, never invented percentages.
    @discardableResult
    func refresh(
        deviceID: String,
        wantedBundleIdentifiers: [String],
        reconciliationPurpose: String = "device-inventory-refresh"
    ) async throws -> DeviceInventoryReconciliation {
        let subject = "device-inventory." + deviceID
        guard PairingRecordDocument.isDeviceIdentifier(deviceID) else {
            throw DeviceLifecycleError.deviceRequired
        }

        guard let taskID = await reporter.beginOnce(
            kind: .deviceSetup,
            title: .localized("Refresh installed-app inventory"),
            subtitle: .localized("Read-only device service query"),
            subjectID: subject
        ) else { throw DeviceLifecycleError.operationBlocked(
            .localized("An inventory read for this device is already running.")
        ) }
        let startedAt = Date()
        do {
            var state = try await store.syncState(deviceID: deviceID) ?? DeviceSyncState(deviceID: deviceID)
            state.lastAttemptAt = startedAt
            state.pendingOperations = 1
            try await store.saveSyncState(state)

            try Task.checkCancellation()
            let request = try await requestProvider()
            guard request.protocolConsent else { throw DeviceTransportError.consentRequired }
            guard PairingRecordInspector.normalize(request.expectedDeviceIdentifier) == deviceID,
                  let expectedBinding = request.binding else {
                throw DeviceTransportError.wrongDevice
            }
            await reporter.report(stage: .inspectingRecord, for: taskID)

            let inventory = try await query.inventory(request: request) { stage in
                Task { @MainActor [weak reporter] in
                    await reporter?.report(stage: stage, for: taskID)
                }
            }
            try Task.checkCancellation()
            guard inventory.binding == expectedBinding else { throw DeviceTransportError.wrongDevice }

            // A successful full-list query is complete as far as this service is concerned.
            // An empty list is not accepted as a device-wide negative: filtered responses are
            // indistinguishable from an empty result from inside the app.
            let isComplete = !inventory.applications.isEmpty
            let previous = try await store.inventory(deviceID: deviceID)
            guard let snapshot = DeviceInventoryReconciler.applying(
                inventory, to: previous, deviceID: deviceID, complete: isComplete
            ) else { throw DeviceLifecycleError.invalidRecord }

            let reconciliation = DeviceInventoryReconciler.reconcile(
                previous: previous, current: snapshot,
                wantedBundleIdentifiers: wantedBundleIdentifiers, now: Date()
            )

            try await store.saveInventory(snapshot)
            state.lastSuccessfulInventoryAt = snapshot.capturedAt
            state.lastSuccessfulSyncAt = Date()
            state.lastAttemptAt = Date()
            state.pendingOperations = 0
            state.status = .synced
            state.summary = LogRedaction.redact(reconciliationPurpose)
            state.updatedAt = Date()
            try await store.saveSyncState(state)

            if var device = try await store.device(id: deviceID) {
                device.lastInventoryAt = snapshot.capturedAt
                device.lastSeenAt = Date()
                if device.link != .connected { device.link = .paired }
                if device.trust == .unknown { device.trust = .unverified }
                try await store.upsert(device)
            }

            await reporter.transition(id: taskID, to: .completed)
            return reconciliation
        } catch {
            let cancelled = error is CancellationError || error as? DeviceTransportError == .operationCancelled
            var state: DeviceSyncState
            do { state = try await store.syncState(deviceID: deviceID) ?? DeviceSyncState(deviceID: deviceID) }
            catch { state = DeviceSyncState(deviceID: deviceID) }
            state.lastAttemptAt = Date()
            state.pendingOperations = 0
            state.status = cancelled ? .interrupted : .failed
            state.summary = LogRedaction.redact(error.localizedDescription)
            state.updatedAt = Date()
            do { try await store.saveSyncState(state) }
            catch { /* The original device error is the one worth reporting. */ }

            await reporter.transition(
                id: taskID, to: cancelled ? .cancelled : .failed,
                error: error.localizedDescription
            )
            if cancelled { throw DeviceLifecycleError.interrupted }
            throw error
        }
    }

    func latestSnapshot(deviceID: String) async throws -> DeviceInventorySnapshot? {
        try await store.inventory(deviceID: deviceID)
    }

    func syncState(deviceID: String) async throws -> DeviceSyncState? {
        try await store.syncState(deviceID: deviceID)
    }
}
