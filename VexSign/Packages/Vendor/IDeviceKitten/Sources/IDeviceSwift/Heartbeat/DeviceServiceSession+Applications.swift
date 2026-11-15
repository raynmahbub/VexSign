// SPDX-License-Identifier: MIT
// Independently written VexSign integration; retain the IDeviceKit wrapper LICENSE.
import Foundation
import Darwin
import IDevice

extension DeviceServiceSession {
    /// Uses the already identity-checked tunnel, never a second peer/session.
    /// Native contract: idevice 0.1.57 ffi/src/core_device/app_service.rs at
    /// 99ea020acabd0579375a09fd690261ea6ca37f68. The returned Box<[AppListEntryC]>
    /// has a matching typed destructor (unlike installation_proxy_get_apps).
    /// Source review is NOT a claim that the XCFramework ABI/device was tested.
    func applicationInventory(cancellation: Progress) throws -> DeviceApplicationInventory {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try Self.check(cancellation)
        guard let snapshot, let adapter, let handshake,
              let binding = DeviceSessionBinding(deviceIdentifier: snapshot.deviceIdentifier,
                                                  pairingSHA256: snapshot.pairingSHA256) else {
            throw DeviceTransportError.invalidDeviceResponse
        }
        var client: OpaquePointer?
        defer { if let client { app_service_free(client) } }
        try checked(app_service_connect_rsd(adapter, handshake, &client), stage: .discoveringServices)
        guard let client else { throw DeviceTransportError.serviceUnavailable("CoreDevice App Service") }
        try Self.check(cancellation)

        var entries: UnsafeMutablePointer<AppListEntryC>?
        var count = 0
        // Only this destructor knows the array layout AND the nested strings.
        // Never use free(), idevice_data_free() or idevice_outer_slice_free().
        defer { if let entries { app_service_free_app_list(entries, count) } }
        try checked(app_service_list_apps(client, 1, 1, 1, 1, 1, &entries, &count), stage: .queryingDevice)
        guard count >= 0, count <= DeviceApplicationInventory.maximumEntries,
              count == 0 || entries != nil else { throw DeviceTransportError.invalidDeviceResponse }
        try Self.check(cancellation)
        var records = [DeviceApplicationInventory.Record]()
        records.reserveCapacity(count)
        if let entries {
            for entry in UnsafeBufferPointer(start: entries, count: count) {
                try Self.check(cancellation)
                guard entry.is_app_clip == 0 || entry.is_app_clip == 1 else {
                    throw DeviceTransportError.invalidDeviceResponse
                }
                records.append(.init(
                    bundleIdentifier: try Self.inventoryString(entry.bundle_identifier, maximumBytes: 255),
                    name: try Self.inventoryString(entry.name, maximumBytes: 1024),
                    version: try Self.optionalInventoryString(entry.version, maximumBytes: 64),
                    build: try Self.optionalInventoryString(entry.bundle_version, maximumBytes: 64),
                    path: try Self.inventoryString(entry.path, maximumBytes: 4096),
                    isAppClip: entry.is_app_clip != 0))
            }
        }
        try Self.check(cancellation)
        return try DeviceApplicationInventory.validated(records, binding: binding, observedAt: Date())
    }

    private static func inventoryString(_ pointer: UnsafePointer<CChar>?, maximumBytes: Int) throws -> String {
        guard let pointer else { throw DeviceTransportError.invalidDeviceResponse }
        let count = strnlen(pointer, maximumBytes + 1)
        guard count > 0, count <= maximumBytes,
              let value = String(bytes: UnsafeRawBufferPointer(start: pointer, count: count), encoding: .utf8) else {
            throw DeviceTransportError.invalidDeviceResponse
        }
        return value
    }

    private static func optionalInventoryString(_ pointer: UnsafePointer<CChar>?, maximumBytes: Int) throws -> String? {
        guard let pointer else { return nil }
        return try inventoryString(pointer, maximumBytes: maximumBytes)
    }
}

extension HeartbeatManager {
    /// Explicit read-only operation. A caller must name its intended device; the
    /// record's HOST UUID and the iPhone running this UI are never substitutes.
    /// An omitted app is unknown, not authoritative device-wide absence.
    public func queryApplicationInventory(request: DeviceConnectionRequest, waiterTimeout: TimeInterval = 30,
                                         reporting: @escaping (DeviceConnectionStage) -> Void = { _ in }) async throws -> DeviceApplicationInventory {
        try await withDeviceSession(request: request, waiterTimeout: waiterTimeout, reporting: reporting) { session, cancellation in
            try session.applicationInventory(cancellation: cancellation)
        }
    }
}
