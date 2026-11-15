// Heartbeat+checks.swift — VexSign local maintenance; MIT upstream notice retained.
import Foundation

extension HeartbeatManager {
    /// Endpoint reachability only. Never interpreted as device trust, a running
    /// third-party VPN, Developer Mode, RSD readiness, or permission to install.
    /// Callers must keep even this bounded BSD socket probe off the main thread.
    public func checkSocketConnection(timeoutInSeconds: Double = 2.0) -> (isConnected: Bool, error: String?) {
        guard !Thread.isMainThread else { return (false, "Run transport diagnostics off the main thread.") }
        do {
            let metadata = try PairingRecordDocument.inspect(PairingFileStorage.read(from: URL(fileURLWithPath: Self.pairingFile())))
            try DeviceTransportPolicy.requireClassicRoute(format: metadata.format, version: .current)
            try DeviceServiceSession.probePeer(UserDefaults.standard.string(forKey: "VexSign.devicePeerAddress") ?? "10.7.0.1",
                timeout: timeoutInSeconds.isFinite ? timeoutInSeconds : 2)
            return (true, nil)
        } catch { return (false, error.localizedDescription) }
    }
}
