// InstallationAppProxy.swift — IDeviceKit (MIT), independently maintained VexSign changes.
import Foundation
import IDevice
import UIKit

public final class InstallationAppProxy: NSObject {
    public var delegate: InstallationProxyAppsDelegate?

    /// Acceptance gate for MUTATIONS. Enabled for the 27+ on-device bootstrap
    /// implementation path; physical-device acceptance on iOS 27.0.1 is still
    /// required before claiming production support. Install confirmation remains
    /// mandatory and is enforced by AppInstaller/InstallConfirmation.
    public static var hasAcceptedInventoryBridge: Bool { true }
    /// Positive inventory cannot establish absence. Removal remains gated pending
    /// physical-device acceptance of absence evidence.
    public static var hasAcceptedRemovalBridge: Bool { false }

    /// Old callers did not identify their target. Do not silently use this
    /// iPhone's local registry or choose a device from an arbitrary remote record.
    public func listApps() async throws { throw DeviceTransportError.expectedDeviceRequired }

    public func listApps(request: DeviceConnectionRequest) async throws {
        let inventory = try await HeartbeatManager.shared.queryApplicationInventory(request: request)
        // Preserve the existing UI/delegate model. Only positive, validated app
        // records are adapted; optional AppInfo metadata stays absent, not guessed.
        let dictionaries: [[String: String]] = inventory.applications.map { app in
            var fields = ["CFBundleIdentifier": app.bundleIdentifier, "CFBundleName": app.name, "Path": app.bundlePath]
            fields["CFBundleShortVersionString"] = app.version
            fields["CFBundleVersion"] = app.build
            return fields
        }
        let apps = try JSONDecoder().decode([AppInfo].self, from: JSONSerialization.data(withJSONObject: dictionaries))
        await MainActor.run { self.delegate?.updateApplications(with: apps) }
    }

    public static func installedApplication(for id: String, request: DeviceConnectionRequest,
                                            waiterTimeout: TimeInterval = 30,
                                            reporting: @escaping (DeviceConnectionStage) -> Void = { _ in }) async throws -> DeviceInstalledApplication? {
        guard DeviceApplicationInventory.isBundleIdentifier(id) else { throw DeviceTransportError.invalidDeviceResponse }
        let inventory = try await HeartbeatManager.shared.queryApplicationInventory(request: request,
            waiterTimeout: waiterTimeout, reporting: reporting)
        return inventory.application(for: id)
    }

    @available(iOS 16.0, macOS 13.0, *)
    public static func deleteApp(for id: String, request: DeviceConnectionRequest? = nil,
                                 control: DeviceInstallationControl = DeviceInstallationControl()) async throws {
        guard hasAcceptedRemovalBridge else { throw DeviceTransportError.inventoryBridgeUnavailable }
        guard let request, request.binding != nil, DeviceApplicationInventory.isBundleIdentifier(id) else {
            throw DeviceTransportError.expectedDeviceRequired
        }
        try await HeartbeatManager.shared.withDeviceSession(request: request) { session, cancellation in
            try DeviceServiceSession.check(cancellation)
            var client: OpaquePointer?
            defer { if let client { installation_proxy_client_free(client) } }
            try session.checked(installation_proxy_connect_rsd(session.adapter, session.handshake, &client), stage: .discoveringServices)
            guard let client else { throw DeviceTransportError.serviceUnavailable("Installation Proxy") }
            try DeviceServiceSession.check(cancellation)
            try control.beginSubmission(at: Date(), cancellation: cancellation)
            try session.checked(installation_proxy_uninstall(client, id, nil), stage: .discoveringServices)
            // This method only acknowledges a request. DeviceAppRemoval must
            // obtain independent, same-device absence evidence before 'Removed'.
        }
    }

    private static var iconCache: [String: UIImage] = [:]
    private static let iconCacheQueue = DispatchQueue(label: "com.vexsign.device-icon-cache")

    public static func getAppIconCached(for id: String) async throws -> UIImage? {
        if let icon = iconCacheQueue.sync(execute: { iconCache[id] }) { return icon }
        let icon = try await getAppIcon(for: id)
        if let icon { iconCacheQueue.sync { iconCache[id] = icon } }
        return icon
    }

    public static func getAppIcon(for id: String) async throws -> UIImage? {
        try await HeartbeatManager.shared.withDeviceSession { session, _ in
            var client: OpaquePointer?
            defer { if let client { springboard_services_free(client) } }
            try session.checked(springboard_services_connect_rsd(session.adapter, session.handshake, &client), stage: .discoveringServices)
            guard let client else { throw DeviceTransportError.serviceUnavailable("SpringBoard Services") }
            var bytes: UnsafeMutableRawPointer?
            var count = 0
            try session.checked(springboard_services_get_icon(client, id, &bytes, &count), stage: .discoveringServices)
            guard let bytes else { throw DeviceTransportError.invalidDeviceResponse }
            // The producer exposes libc size_t (Swift Int), while this Rust
            // usize destructor is imported as UInt. Preserve the native bits.
            defer { idevice_data_free(bytes.assumingMemoryBound(to: UInt8.self), UInt(bitPattern: count)) }
            guard count > 0, count <= 8 * 1024 * 1024 else { throw DeviceTransportError.invalidDeviceResponse }
            return UIImage(data: Data(bytes: bytes, count: count))
        }
    }
}
