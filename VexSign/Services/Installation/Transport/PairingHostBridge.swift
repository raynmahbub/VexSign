// App-facing bridge for on-device RPPairing host bootstrap (iOS 27+).
// Uses the existing PairingHostSession/PairingFileStorage owners; no UI-owned native handles.
import Foundation
import IDeviceSwift
import NimbleExtensions

struct OnDevicePairingProgress: Sendable {
    let stage: String
    let pin: String?
}

@MainActor
final class PairingHostBridge {
    private var session: PairingHostSession?

    nonisolated static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 27, *) { return DevicePairingRoute.resolve(.current) == .onDeviceHostPairing }
        return false
        #endif
    }

    func cancel() {
        session?.cancel()
    }

    func startOnDevicePairing(
        replacing reviewedFingerprint: String?,
        timeoutSeconds: UInt32 = 180,
        reporting: @escaping @Sendable (OnDevicePairingProgress) -> Void
    ) async throws -> PairingRecordMetadata {
        guard Self.isSupported else { throw DeviceTransportError.hostUnavailable }
        let session = PairingHostSession()
        self.session = session
        defer { self.session = nil }

        reporting(OnDevicePairingProgress(stage: String.localized("Preparing pairing host…"), pin: nil))
        let name = "VexSign"
        let advertisement = try session.prepare(name: name)
        reporting(OnDevicePairingProgress(stage: String.localized("Advertising pairing host. Open Settings > Privacy & Security > Developer Mode and tap Pair with %@.", arguments: name), pin: nil))

        let result = try await session.advertiseAndAccept(advertisement: advertisement, timeoutSeconds: timeoutSeconds) { pin in
            reporting(OnDevicePairingProgress(stage: String.localized("Enter this PIN on your iPhone to confirm pairing."), pin: pin))
        }

        reporting(OnDevicePairingProgress(stage: String.localized("Validating and storing pairing record…"), pin: nil))
        let metadata = try await HeartbeatManager.shared.installPairingRecordData(result.recordData, replacing: reviewedFingerprint)
        guard metadata.format.containsRemotePairing else { throw PairingRecordError.unsupportedFormat }
        reporting(OnDevicePairingProgress(stage: String.localized("Pairing record stored. Verification is required before any device operation."), pin: nil))
        return metadata
    }
}
