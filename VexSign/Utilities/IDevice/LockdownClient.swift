// MARK: - LockdownClient
/// Answers "which device is this?" from evidence the app actually holds.
///
/// Two sources, and the difference between them matters:
///
/// * **The pairing file** — the record imported in Settings → Installation. It is the evidence that
///   a pairing exists at all, and it carries the UDID (`DeviceID`). Nothing else in it names the
///   device.
/// * **The running device** — VexSign installs onto the device it runs on, so that record describes
///   this device. Its name, iOS version, build number and hardware model come from the local system.
///
/// A live lockdownd session over USB would answer the same questions from the device itself. The
/// `IDevice` binary this target links does export one, but as a C FFI — `idevice_pairing_file_read`
/// → `usbmuxd_provider_new` → `lockdownd_connect` → `lockdownd_start_session` →
/// `lockdownd_get_value`, with the answers arriving as `plist_t` — and not as the libimobiledevice
/// API (`lockdown_client_new_with_pairing_file`, `lockdown_get_value`, `lockdown_free_value`,
/// `lockdown_client_free`) this file used to call. Those symbols are not in the pinned xcframework
/// (jkcoxson/idevice v0.1.57), so the calls never compiled, and the FFI needs a real device on the
/// other end of the cable to be worth writing. Until then these queries answer from the two sources
/// above.

import Foundation
import IDeviceSwift
import UIKit
import os

/// Errors that can occur when communicating with the device via Lockdown.
public enum LockdownClientError: LocalizedError, Equatable {
    case pairingFileNotFound
    case invalidPairingFile
    case connectionFailed(String)
    case deviceNotFound
    case queryFailed(String)
    case invalidResponse
    case sslError(String)

    public var errorDescription: String? {
        switch self {
        case .pairingFileNotFound:
            return "Pairing file not found. Please configure a pairing file in Settings → Installation."
        case .invalidPairingFile:
            return "The pairing file is invalid or corrupted."
        case .connectionFailed(let msg):
            return "Failed to connect to device: \(msg)"
        case .deviceNotFound:
            return "No device found. Ensure the device is connected via USB and trusted."
        case .queryFailed(let msg):
            return "Device query failed: \(msg)"
        case .invalidResponse:
            return "Received invalid response from device."
        case .sslError(let msg):
            return "SSL/TLS error: \(msg)"
        }
    }
}

/// Client for querying information about the device VexSign signs for.
public actor LockdownClient {
    private let pairingFileURL: URL
    private let logger = Logger(subsystem: "com.vexsign", category: "LockdownClient")
    /// Set by `connect()`. Every query refuses to run before a pairing file has been accepted, so
    /// an unconnected client reports the missing connection instead of answering anyway.
    private var isConnected = false

    /// Creates a new LockdownClient with the given pairing file.
    /// - Parameter pairingFileURL: URL to the .mobiledevicepairing or pairingFile.plist
    public init(pairingFileURL: URL) {
        self.pairingFileURL = pairingFileURL
    }

    /// Accepts the pairing file. A missing file and an unreadable one have different fixes, so the
    /// read happens here rather than being deferred to the first query.
    public func connect() async throws {
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw LockdownClientError.pairingFileNotFound
        }

        guard let data = try? Data(contentsOf: pairingFileURL), // try? ok: the unreadable file is the failure being reported
              let udid = Self.udid(in: data) else {
            logger.error("The pairing file is not a readable pairing record")
            throw LockdownClientError.invalidPairingFile
        }

        isConnected = true
        logger.debug("Pairing record accepted for \(udid, privacy: .public)")
    }

    /// Ends the session. Nothing to release: no device handle is held open.
    public func disconnect() {
        isConnected = false
    }

    /// Gets the device name.
    public func getDeviceName() async throws -> String {
        try requireConnection()
        return await LocalDeviceIdentity.read().name
    }

    /// Gets the device type (e.g., "iPhone", "iPad").
    public func getDeviceType() async throws -> String {
        try requireConnection()
        return deviceType(forHardwareModel: hardwareModelIdentifier())
    }

    /// Gets the iOS version (e.g., "17.2").
    public func getProductVersion() async throws -> String {
        try requireConnection()
        return await LocalDeviceIdentity.read().systemVersion
    }

    /// Gets the build version (e.g., "21C62"), when the system reports one.
    public func getBuildVersion() async throws -> String {
        try requireConnection()
        return buildNumber(from: ProcessInfo.processInfo.operatingSystemVersionString) ?? "unknown"
    }

    /// Gets the hardware model identifier (e.g., "iPhone15,2").
    ///
    /// Lockdown's `ModelNumber` is the order number ("MQ6M3LL/A"); the identifier is what the rest
    /// of the app matches hardware against — `IPSWBrowser` keys its catalogue off the same string.
    public func getModelNumber() async throws -> String {
        try requireConnection()
        let model = hardwareModelIdentifier()
        return model.isEmpty ? "unknown" : model
    }

    /// Gets the device UDID from the pairing file.
    public func getUDID() async throws -> String {
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw LockdownClientError.pairingFileNotFound
        }

        guard let data = try? Data(contentsOf: pairingFileURL), // try? ok: missing or unreadable file is the failure being reported
              let udid = Self.udid(in: data) else {
            throw LockdownClientError.invalidPairingFile
        }
        return udid
    }

    /// Gets all device info in a single call.
    public func getDeviceInfo() async throws -> DeviceInfo {
        let udid = try await getUDID()
        let name = try await getDeviceName()
        let deviceType = try await getDeviceType()
        let iosVersion = try await getProductVersion()
        let buildVersion = try await getBuildVersion()
        let modelNumber = try await getModelNumber()

        return DeviceInfo(
            udid: udid,
            name: name,
            deviceType: deviceType,
            iosVersion: iosVersion,
            buildVersion: buildVersion,
            modelNumber: modelNumber,
            isTrusted: true // If the pairing record is readable, the device is trusted
        )
    }

    // MARK: - Internals

    private func requireConnection() throws {
        guard isConnected else {
            throw LockdownClientError.connectionFailed("Not connected")
        }
    }

    /// The `DeviceID` entry of a pairing record, which is the device's UDID.
    private static func udid(in data: Data) -> String? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { // try? ok: an unparseable record is reported as invalidPairingFile by the caller
            return nil
        }
        return plist["DeviceID"] as? String
    }
}

/// Convenience function to get device info from the default pairing file.
public func getPairedDeviceInfo() async throws -> DeviceInfo {
    let pairingFileURL = URL(fileURLWithPath: HeartbeatManager.pairingFile())

    let client = LockdownClient(pairingFileURL: pairingFileURL)
    try await client.connect()
    let info = try await client.getDeviceInfo()
    await client.disconnect()
    return info
}

// MARK: - Local identity

/// What the running device reports about itself.
///
/// `UIDevice` is a main-actor API, so the reads are taken as one snapshot there instead of hopping
/// for each value.
@MainActor
private struct LocalDeviceIdentity: Sendable {
    let name: String
    let systemVersion: String

    static func read() -> LocalDeviceIdentity {
        LocalDeviceIdentity(
            name: UIDevice.current.name,
            systemVersion: UIDevice.current.systemVersion
        )
    }
}

/// `utsname.machine` — the hardware identifier, spelled the way the firmware catalogue spells it.
private func hardwareModelIdentifier() -> String {
    var system = utsname()
    uname(&system)
    let mirror = Mirror(reflecting: system.machine)
    let identifier = mirror.children.reduce(into: "") { partial, element in
        guard let value = element.value as? Int8, value != 0 else { return }
        partial.append(Character(UnicodeScalar(UInt8(value))))
    }
    return identifier.trimmingCharacters(in: .whitespaces)
}

/// The family the hardware identifier belongs to. `DevicePickerView` picks its row icon off the
/// lowercased form of this string.
private func deviceType(forHardwareModel model: String) -> String {
    if model.hasPrefix("iPhone") { return "iPhone" }
    if model.hasPrefix("iPad") { return "iPad" }
    if model.hasPrefix("iPod") { return "iPod touch" }
    return "iOS Device"
}

/// The build number out of `operatingSystemVersionString` — "Version 17.2 (Build 21C62)".
private func buildNumber(from versionString: String) -> String? {
    guard let open = versionString.range(of: "(Build ") else { return nil }
    let rest = versionString[open.upperBound...]
    guard let close = rest.range(of: ")") else { return nil }
    let build = String(rest[rest.startIndex..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
    return build.isEmpty ? nil : build
}
