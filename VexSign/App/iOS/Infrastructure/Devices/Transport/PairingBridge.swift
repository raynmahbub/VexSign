// App-facing adapter for the existing record/storage/native executor owners.
// Views never own a native pointer, import a transport framework, or infer trust from a file.
import Foundation
import IDeviceSwift
import NimbleExtensions

struct BootstrapPairingReview {
    let state: DevicePairingState
    let fingerprint: String?
    let format: PairingRecordFormat?
    let deviceIdentifier: String?
}

enum PairingBridge {
    static var pairingFilePath: String { HeartbeatManager.pairingFile() }
    static var pairingFileURL: URL { URL(fileURLWithPath: pairingFilePath) }
    static var hasPairingFile: Bool { FileManager.default.fileExists(atPath: pairingFilePath) }
    static var isBusy: Bool { HeartbeatManager.shared.isBusy }

    @MainActor private static var selectedDeviceRequest: DeviceConnectionRequest?

    @MainActor static func invalidateSelectedDevice() {
        HeartbeatManager.shared.cancelDeviceOperations()
        selectedDeviceRequest = nil
        LibraryStatusStore.shared.selectDevice(binding: nil)
    }

    @MainActor static func isSelectedForUse(_ request: DeviceConnectionRequest) -> Bool {
        protocolConsent && request.protocolConsent && request.binding != nil
            && request.binding == selectedDeviceRequest?.binding
            && request.peerAddress == peerAddress && request.pairingFile == pairingFileURL
    }

    @MainActor static var protocolConsent: Bool {
        get { UserDefaults.standard.bool(forKey: "VexSign.deviceProtocolConsent") }
        set {
            UserDefaults.standard.set(newValue, forKey: "VexSign.deviceProtocolConsent")
            if !newValue {
                HeartbeatManager.shared.cancelDeviceOperations()
                invalidateSelectedDevice()
            }
        }
    }

    @MainActor static var peerAddress: String {
        get { UserDefaults.standard.string(forKey: "VexSign.devicePeerAddress") ?? "10.7.0.1" }
        set {
            let changed = newValue != peerAddress
            UserDefaults.standard.set(newValue, forKey: "VexSign.devicePeerAddress")
            if changed {
                HeartbeatManager.shared.cancelDeviceOperations()
                invalidateSelectedDevice()
            }
        }
    }

    static var route: DevicePairingRoute { .resolve(.current) }
    static var routeTitle: String {
        switch route {
        case .unsupported: return .localized("Paired route unavailable on this OS")
        case .importedClassic: return .localized("Classic pairing candidate — device testing pending")
        case .importedRemoteRequired: return .localized("Remote Pairing import — companion required")
        case .hostDependencyRequired: return .localized("On-device RPPairing host unavailable")
        case .unknownOS: return .localized("OS compatibility unknown")
        }
    }
    static var routeDetail: String {
        switch route {
        case .unsupported:
            return .localized("Below iOS 17.4, this foundation does not provide a paired-device route. Use an eligible external installer or signed IPA export.")
        case .importedClassic:
            return .localized("iOS 17.4–26.3: import a compatible classic lockdown record, enable Developer Mode yourself, and activate the required VPN in its own app. A fresh read-only device query is experimental, not proof that installation is supported.")
        case .importedRemoteRequired:
            return .localized("iOS 26.4–26.7: a compatible Remote Pairing file is required; a lockdown record is not equivalent. A computer may be necessary to generate it. This build can inspect and preserve the file, but its pinned native library has no accepted modern loopback bridge.")
        case .hostDependencyRequired:
            return .localized("iOS 27+: the pinned library exposes no accepted RPPairing host. VexSign cannot advertise a host, invent a PIN, enable Developer Mode, or create trust through a public iOS API established by this review. Use a compatible companion; importing a remote record alone does not unlock transport.")
        case .unknownOS:
            return .localized("This OS falls outside the reviewed compatibility matrix. No pairing route is enabled. Use an eligible external installer or export a signed IPA.")
        }
    }

    static var pairedInventoryAccepted: Bool { InstallationAppProxy.hasAcceptedInventoryBridge }
    static var pairedRemovalAccepted: Bool { InstallationAppProxy.hasAcceptedRemovalBridge }
    static var pairedInstallationLimitation: String { DeviceTransportError.inventoryBridgeUnavailable.localizedDescription }

    static func recoverLocalStorage() async throws {
        try await HeartbeatManager.shared.recoverPairingStorage()
    }

    static func inspectPairingRecord() -> DevicePairingState {
        PairingRecordInspector.inspect(fileAt: pairingFileURL)
    }

    static func reviewRecord() async throws -> BootstrapPairingReview {
        let review = try await HeartbeatManager.shared.currentPairingReview()
        let state: DevicePairingState
        if let metadata = review.metadata {
            state = metadata.format == .lockdown && metadata.deviceIdentifier != nil
                ? .readable(udid: metadata.deviceIdentifier ?? "")
                : .validated(format: metadata.format, deviceIdentifier: metadata.deviceIdentifier)
        } else { state = PairingRecordInspector.state(for: review.issue ?? .unreadable) }
        return BootstrapPairingReview(state: state, fingerprint: review.fingerprint,
            format: review.metadata?.format, deviceIdentifier: review.metadata?.deviceIdentifier)
    }

    static func importRecord(from url: URL, replacing fingerprint: String?) async throws {
        try await CertificateManagementService.installPairingFile(from: url, replacing: fingerprint)
    }

    static func deleteRecord(fingerprint: String) async throws {
        try await HeartbeatManager.shared.deletePairingRecord(expectedSHA256: fingerprint)
        await MainActor.run { invalidateSelectedDevice() }
    }

    static func prepareExport(fingerprint: String) async throws -> URL {
        try await HeartbeatManager.shared.exportPairingRecord(expectedSHA256: fingerprint)
    }

    static func discardExport(at url: URL) {
        // Dismissal can arrive on the main actor. Storage's existing lock
        // serializes cleanup with preparation; no blocking filesystem IO here.
        Task.detached(priority: .utility) { PairingFileStorage.discardExport(at: url) }
    }

    static func canQuery(_ state: DevicePairingState, expectedIdentifier: String) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return route == .importedClassic && state.format?.containsLockdown == true
            && PairingRecordDocument.isDeviceIdentifier(PairingRecordDocument.normalizeDeviceIdentifier(expectedIdentifier))
        #endif
    }

    @MainActor
    static func queryDevice(expectedIdentifier: String, fingerprint: String? = nil,
                            reporting: @escaping (DeviceConnectionStage) -> Void) async throws -> AuthorizedDeviceSnapshot {
        let request = DeviceConnectionRequest(pairingFile: pairingFileURL,
            expectedDeviceIdentifier: expectedIdentifier, peerAddress: peerAddress, protocolConsent: protocolConsent,
            expectedPairingSHA256: fingerprint)
        let snapshot = try await HeartbeatManager.shared.queryDevice(request: request, reporting: reporting)
        try Task.checkCancellation()
        guard protocolConsent, request.peerAddress == peerAddress else { throw DeviceTransportError.operationCancelled }
        // The user explicitly named this device in setup. Remember selection,
        // never enduring authorization. A new attempt rechecks record and identity.
        let selected = DeviceConnectionRequest(pairingFile: pairingFileURL,
            expectedDeviceIdentifier: snapshot.deviceIdentifier, peerAddress: request.peerAddress,
            protocolConsent: true, expectedPairingSHA256: snapshot.pairingSHA256)
        guard selected.binding != nil else { throw DeviceTransportError.invalidDeviceResponse }
        selectedDeviceRequest = selected
        LibraryStatusStore.shared.selectDevice(binding: selected.binding)
        return snapshot
    }

    /// Freeze the reviewed classic record for one user-initiated install attempt.
    /// Every later native operation still re-reads the credential and queries the
    /// actual device. No HOST identifier or UIDevice metadata is substituted.
    @MainActor
    static func installationRequest() async throws -> DeviceConnectionRequest {
        guard let request = selectedDeviceRequest else { throw DeviceTransportError.expectedDeviceRequired }
        let metadata = try await HeartbeatManager.shared.currentPairingRecord()
        guard isSelectedForUse(request), metadata.sha256 == request.expectedPairingSHA256 else {
            throw DeviceTransportError.operationCancelled
        }
        return request
    }

    @MainActor
    static func queryInstalledApplication(_ identifier: String, expectedDevice: String, fingerprint: String?,
                                         reporting: @escaping (DeviceConnectionStage) -> Void) async throws -> DeviceInstalledApplication? {
        let request = DeviceConnectionRequest(pairingFile: pairingFileURL, expectedDeviceIdentifier: expectedDevice,
            peerAddress: peerAddress, protocolConsent: protocolConsent, expectedPairingSHA256: fingerprint)
        return try await InstallationAppProxy.installedApplication(for: identifier, request: request, reporting: reporting)
    }

    /// Retained for advanced endpoint diagnostics. An open socket establishes no trust.
    static func restartHeartbeat() { HeartbeatManager.shared.start(true) }
    static func isSocketConnected() -> Bool { HeartbeatManager.shared.checkSocketConnection().isConnected }
}

// MARK: - Existing device picker (record discovery only)

@MainActor
final class IDeviceManager {
    static let shared = IDeviceManager()
    private init() {}

    struct Result: Sendable {
        let pairing: DevicePairingState
        let devices: [PairedDeviceRecord]
    }

    /// Discovery must not initiate a native handshake or borrow this iPhone's
    /// UIDevice metadata to describe an arbitrary record. Verify explicitly in setup.
    func pairedDevices() async -> Result {
        let pairing = await Task.detached(priority: .utility) {
            PairingRecordInspector.inspect(fileAt: PairingBridge.pairingFileURL)
        }.value
        guard let udid = pairing.udid else { return Result(pairing: pairing, devices: []) }
        let record = PairedDeviceRecord(udid: udid, name: .localized("iOS Device"),
            deviceType: .localized("Unknown"), iosVersion: .localized("Unknown"),
            presence: .discovered, pairing: pairing, trust: .unverified)
        return Result(pairing: pairing, devices: PairedDeviceRecord.unique([record]))
    }
}
