// MARK: - LockdownClient
/// IDeviceSwift-based Lockdown client for querying device information via USB.
//  Used by DevicePickerView to get paired device details (name, iOS version, device type).

import Foundation
import IDeviceSwift

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

/// Lockdown client for querying device information.
/// Uses IDeviceSwift's lockdown service over USB/TCPIP.
public actor LockdownClient {
    private let pairingFileURL: URL
    private var lockdownClient: LockdownClientHandle?
    private let logger = Logger(subsystem: "com.vexsign", category: "LockdownClient")

    // IDeviceSwift C types
    private typealias LockdownClientHandle = OpaquePointer
    private typealias LockdownError = Int32

    /// Creates a new LockdownClient with the given pairing file.
    /// - Parameter pairingFileURL: URL to the .mobiledevicepairing or pairingFile.plist
    public init(pairingFileURL: URL) {
        self.pairingFileURL = pairingFileURL
    }

    /// Connects to the device via USB using the pairing file.
    public func connect() async throws {
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw LockdownClientError.pairingFileNotFound
        }

        try await Task.detached(priority: .utility) { [pairingFileURL] in
            var client: LockdownClientHandle?
            var pairingFile: OpaquePointer?

            // Read the pairing file
            let result = idevice_pairing_file_read(pairingFileURL.path, &pairingFile)
            guard result == 0, let pairingFile = pairingFile else {
                throw LockdownClientError.invalidPairingFile
            }
            defer { idevice_pairing_file_free(pairingFile) }

            // Create lockdown client
            let error = lockdown_client_new_with_pairing_file(pairingFile, &client)
            guard error == 0, let client = client else {
                throw LockdownClientError.connectionFailed("lockdown_client_new_with_pairing_file returned \(error)")
            }

            await MainActor.run {
                self.lockdownClient = client
            }
        }.value
    }

    /// Disconnects from the device.
    public func disconnect() {
        if let client = lockdownClient {
            lockdown_client_free(client)
            lockdownClient = nil
        }
    }

    /// Gets the device name.
    public func getDeviceName() async throws -> String {
        try await queryValue(key: "DeviceName")
    }

    /// Gets the device type (e.g., "iPhone", "iPad").
    public func getDeviceType() async throws -> String {
        try await queryValue(key: "DeviceClass")
    }

    /// Gets the iOS version (e.g., "17.2").
    public func getProductVersion() async throws -> String {
        try await queryValue(key: "ProductVersion")
    }

    /// Gets the build version (e.g., "21C62").
    public func getBuildVersion() async throws -> String {
        try await queryValue(key: "BuildVersion")
    }

    /// Gets the model number (e.g., "iPhone15,2").
    public func getModelNumber() async throws -> String {
        try await queryValue(key: "ModelNumber")
    }

    /// Gets the device UDID from the pairing file.
    public func getUDID() async throws -> String {
        // The UDID is in the pairing file
        guard let data = try? Data(contentsOf: pairingFileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let udid = plist["DeviceID"] as? String else {
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
            isTrusted: true // If we can connect, the device is trusted
        )
    }

    /// Queries a single value from Lockdown.
    private func queryValue(key: String) async throws -> String {
        guard let client = lockdownClient else {
            throw LockdownClientError.connectionFailed("Not connected")
        }

        return try await withCheckedThrowingContinuation { continuation in
            var value: UnsafeMutablePointer<CChar>? = nil
            let error = lockdown_get_value(client, key, &value)

            if error != 0 {
                continuation.resume(throwing: LockdownClientError.queryFailed("lockdown_get_value(\(key)) returned \(error)"))
                return
            }

            guard let value = value else {
                continuation.resume(throwing: LockdownClientError.invalidResponse)
                return
            }

            let string = String(cString: value)
            lockdown_free_value(value)
            continuation.resume(returning: string)
        }
    }

    deinit {
        disconnect()
    }
}

/// Convenience function to get device info from the default pairing file.
public func getPairedDeviceInfo() async throws -> DeviceInfo {
    let pairingFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("pairingFile.plist")

    let client = LockdownClient(pairingFileURL: pairingFileURL)
    try await client.connect()
    let info = try await client.getDeviceInfo()
    await client.disconnect()
    return info
}