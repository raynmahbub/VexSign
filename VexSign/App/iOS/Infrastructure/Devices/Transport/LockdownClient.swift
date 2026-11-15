// VexSign's adapter for an actual, short-lived device-service identity query.
// A returned snapshot is point-in-time evidence, not a persistent live session.
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

public actor LockdownClient {
    private let pairingFileURL: URL
    private var snapshot: AuthorizedDeviceSnapshot?
    private var generation = UUID()

    public init(pairingFileURL: URL) { self.pairingFileURL = pairingFileURL }

    public func connect() async throws {
        let operation = UUID()
        generation = operation
        snapshot = nil
        let metadata = try await HeartbeatManager.shared.inspectPairingRecord(from: pairingFileURL)
        try Task.checkCancellation()
        guard generation == operation else { throw CancellationError() }
        let request = DeviceConnectionRequest(pairingFile: pairingFileURL,
            expectedDeviceIdentifier: metadata.deviceIdentifier ?? "",
            peerAddress: UserDefaults.standard.string(forKey: "VexSign.devicePeerAddress") ?? "10.7.0.1",
            protocolConsent: UserDefaults.standard.bool(forKey: "VexSign.deviceProtocolConsent"))
        let evidence = try await HeartbeatManager.shared.queryDevice(request: request)
        try Task.checkCancellation()
        guard generation == operation else { throw CancellationError() }
        snapshot = evidence
    }

    public func disconnect() { generation = UUID(); snapshot = nil }

    public func getDeviceName() throws -> String { try requireSnapshot().name }
    public func getDeviceType() throws -> String {
        let type = try requireSnapshot().productType
        if type.hasPrefix("iPhone") { return "iPhone" }
        if type.hasPrefix("iPad") { return "iPad" }
        return type
    }
    public func getProductVersion() throws -> String { try requireSnapshot().productVersion }
    public func getBuildVersion() throws -> String { try requireSnapshot().buildVersion }
    public func getModelNumber() throws -> String { try requireSnapshot().productType }
    public func getUDID() throws -> String { try requireSnapshot().deviceIdentifier }

    public func getDeviceInfo() throws -> DeviceInfo {
        let evidence = try requireSnapshot()
        return DeviceInfo(udid: evidence.deviceIdentifier, name: evidence.name,
            deviceType: try getDeviceType(), iosVersion: evidence.productVersion,
            buildVersion: evidence.buildVersion, modelNumber: evidence.productType, trust: .verified)
    }

    private func requireSnapshot() throws -> AuthorizedDeviceSnapshot {
        guard let snapshot else { throw LockdownClientError.connectionFailed("No verified device-service query") }
        return snapshot
    }
}

public func getPairedDeviceInfo() async throws -> DeviceInfo {
    let client = LockdownClient(pairingFileURL: URL(fileURLWithPath: HeartbeatManager.pairingFile()))
    try await client.connect()
    let info = try await client.getDeviceInfo()
    await client.disconnect()
    return info
}
