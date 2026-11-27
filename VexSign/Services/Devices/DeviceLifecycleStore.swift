// MARK: - Durable device records
//
// Device rows and inventory snapshots use the existing disposable ecosystem SQLite store.
// WAL commits are atomic, so an interrupted write cannot leave a half-written record. This is
// not a second database or a second device transport: it only persists what a supported
// pairing query already established.

import Foundation
import IDeviceSwift
import NimbleExtensions

actor DeviceLifecycleStore {
    private let database: EcosystemDatabase
    private let recordsKey = "device.lifecycle.records.v1"
    private let inventoryPrefix = "device.lifecycle.inventory.v1."
    private let syncPrefix = "device.lifecycle.sync.v1."

    init(database: EcosystemDatabase) {
        self.database = database
    }

    // MARK: Devices

    func devices() async throws -> [ManagedDeviceRecord] {
        guard let collection = try await database.read(recordsKey, as: ManagedDeviceCollection.self) else {
            return []
        }
        guard collection.isWellFormed else { throw DeviceLifecycleError.invalidRecord }
        return collection.devices
    }

    /// Replaces the collection only as a whole. Records that are not well formed are never
    /// written; a corrupt decoded collection leaves the previous snapshot intact.
    func save(devices: [ManagedDeviceRecord]) async throws {
        let collection = ManagedDeviceCollection(devices: devices)
        guard collection.isWellFormed, devices.count <= ManagedDeviceRecord.maximumRecords else {
            throw DeviceLifecycleError.invalidRecord
        }
        try await database.write(collection, key: recordsKey)
    }

    func device(id: String) async throws -> ManagedDeviceRecord? {
        guard !id.isEmpty else { throw DeviceLifecycleError.invalidIdentifier }
        let all = try await devices()
        return all.first { $0.id == id }
    }

    func upsert(_ device: ManagedDeviceRecord) async throws {
        guard device.isWellFormed else { throw DeviceLifecycleError.invalidRecord }
        var devices = try await devices()
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            guard devices.count < ManagedDeviceRecord.maximumRecords else {
                throw DeviceLifecycleError.invalidRecord
            }
            devices.append(device)
        }
        try await save(devices: devices)
    }

    func removeDevice(id: String) async throws {
        guard !id.isEmpty else { throw DeviceLifecycleError.invalidIdentifier }
        var devices = try await devices()
        devices.removeAll { $0.id == id }
        try await save(devices: devices)
        try await database.delete(inventoryKey(id))
        try await database.delete(syncKey(id))
    }

    // MARK: Inventory

    func inventory(deviceID: String) async throws -> DeviceInventorySnapshot? {
        guard validKeyComponent(deviceID) else { throw DeviceLifecycleError.invalidIdentifier }
        guard let snapshot = try await database.read(inventoryKey(deviceID), as: DeviceInventorySnapshot.self) else {
            return nil
        }
        guard snapshot.isWellFormed, snapshot.deviceID == deviceID else {
            throw DeviceLifecycleError.invalidRecord
        }
        return snapshot
    }

    func saveInventory(_ snapshot: DeviceInventorySnapshot) async throws {
        guard snapshot.isWellFormed else { throw DeviceLifecycleError.invalidRecord }
        try await database.write(snapshot, key: inventoryKey(snapshot.deviceID))
    }

    // MARK: Sync state

    func syncState(deviceID: String) async throws -> DeviceSyncState? {
        guard validKeyComponent(deviceID) else { throw DeviceLifecycleError.invalidIdentifier }
        guard let state = try await database.read(syncKey(deviceID), as: DeviceSyncState.self) else { return nil }
        guard state.isWellFormed, state.deviceID == deviceID else { throw DeviceLifecycleError.invalidRecord }
        return state
    }

    func saveSyncState(_ state: DeviceSyncState) async throws {
        guard state.isWellFormed else { throw DeviceLifecycleError.invalidRecord }
        try await database.write(state, key: syncKey(state.deviceID))
    }

    private func inventoryKey(_ deviceID: String) -> String { inventoryPrefix + deviceID }
    private func syncKey(_ deviceID: String) -> String { syncPrefix + deviceID }

    private func validKeyComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 70)
                || (scalar.value >= 97 && scalar.value <= 102) || scalar.value == 45 || scalar.value == 95
        }
    }
}

// MARK: - Inventory snapshots

/// A positive-only snapshot. A missing bundle is *not* represented as an uninstalled app:
/// the native service can return a filtered list, so only observed records are stored.
struct DeviceInventorySnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumApplications = 10_000

    let schemaVersion: Int
    let deviceID: String
    /// Opaque session token. It proves which pairing/device pair produced the reading; the
    /// pairing credential itself is never persisted.
    let sessionBinding: DeviceSessionBinding
    let capturedAt: Date
    /// `true` when the device service returned a complete inventory. `false` means the query
    /// was scoped or partially understood, so omissions must not be treated as removals.
    let isComplete: Bool
    let applications: [ManagedInstalledApplication]

    init(deviceID: String, sessionBinding: DeviceSessionBinding, capturedAt: Date,
         isComplete: Bool, applications: [ManagedInstalledApplication]) {
        self.schemaVersion = Self.schemaVersion
        self.deviceID = deviceID
        self.sessionBinding = sessionBinding
        self.capturedAt = capturedAt
        self.isComplete = isComplete
        self.applications = applications.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    var isWellFormed: Bool {
        schemaVersion == Self.schemaVersion
            && !deviceID.isEmpty && deviceID.utf8.count <= 128
            && sessionBinding.isWellFormed
            && applications.count <= Self.maximumApplications
            && Set(applications.map(\.bundleIdentifier)).count == applications.count
            && applications.allSatisfy(\.isWellFormed)
            && capturedAt.timeIntervalSince1970 >= 0
    }

    func application(bundleIdentifier: String) -> ManagedInstalledApplication? {
        applications.first { $0.bundleIdentifier == bundleIdentifier }
    }

    var age: TimeInterval { max(0, Date().timeIntervalSince(capturedAt)) }

    var isStale: Bool { age > DeviceInventoryFreshness.staleInterval }

    var freshnessTitle: String {
        if isStale { return .localized("Stale inventory") }
        return .localized("Recent inventory")
    }
}

/// Public metadata only. `bundlePath`, UDIDs, receipts and container paths are intentionally
/// absent; a device service response is not an invitation to retain them.
struct ManagedInstalledApplication: Codable, Equatable, Sendable, Identifiable {
    static let maximumNameBytes = 1024

    let bundleIdentifier: String
    let name: String
    let version: String?
    let build: String?
    let observedAt: Date
    /// Missing version/build stays missing. It is never copied from a library record.
    var hasComparableMetadata: Bool {
        version.map(DeviceApplicationInventory.isVersion) == true
            && build.map(DeviceApplicationInventory.isVersion) == true
    }

    var id: String { bundleIdentifier }

    init(bundleIdentifier: String, name: String, version: String?, build: String?, observedAt: Date) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.build = build
        self.observedAt = observedAt
    }

    init?(reading: DeviceInstalledApplication) {
        guard DeviceApplicationInventory.isBundleIdentifier(reading.bundleIdentifier),
              !reading.name.isEmpty, reading.name.utf8.count <= Self.maximumNameBytes,
              !reading.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              reading.version.map(DeviceApplicationInventory.isVersion) ?? true,
              reading.build.map(DeviceApplicationInventory.isVersion) ?? true,
              reading.observedAt.timeIntervalSince1970 >= 0 else { return nil }
        self.init(bundleIdentifier: reading.bundleIdentifier, name: reading.name,
                  version: reading.version, build: reading.build, observedAt: reading.observedAt)
    }

    var isWellFormed: Bool {
        DeviceApplicationInventory.isBundleIdentifier(bundleIdentifier)
            && !name.isEmpty && name.utf8.count <= Self.maximumNameBytes
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && (version.map(DeviceApplicationInventory.isVersion) ?? true)
            && (build.map(DeviceApplicationInventory.isVersion) ?? true)
            && observedAt.timeIntervalSince1970 >= 0
    }
}

enum DeviceInventoryFreshness {
    static let staleInterval: TimeInterval = 15 * 60
}

/// Per-device synchronization state. `lastSuccessfulSyncAt` is only written after a whole
/// inventory pass and reconciliation have completed; partial reads do not advance it.
struct DeviceSyncState: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let deviceID: String
    var lastAttemptAt: Date?
    var lastSuccessfulSyncAt: Date?
    var lastSuccessfulInventoryAt: Date?
    var status: Status
    var summary: String?
    var pendingOperations: Int
    var updatedAt: Date

    enum Status: String, Codable, Sendable {
        case never, synced, stale, failed, interrupted
    }

    init(deviceID: String) {
        self.schemaVersion = Self.schemaVersion
        self.deviceID = deviceID
        self.status = .never
        self.pendingOperations = 0
        self.updatedAt = Date()
    }

    var isWellFormed: Bool {
        schemaVersion == Self.schemaVersion && !deviceID.isEmpty && deviceID.utf8.count <= 128
            && pendingOperations >= 0 && pendingOperations <= 10_000
            && (summary?.utf8.count ?? 0) <= 1024
    }

    var title: String {
        switch status {
        case .never: .localized("Not synchronized")
        case .synced: .localized("Synchronized")
        case .stale: .localized("Synchronization stale")
        case .failed: .localized("Synchronization failed")
        case .interrupted: .localized("Synchronization interrupted")
        }
    }
}
