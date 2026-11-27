// MARK: - Device registry
//
// One durable row per device. Pairing discovery and identity verification are deliberately
// separate: reviewing a file only records that the file is readable, while a fresh device
// query is the only thing that can say the device answered and is connected now.

import Foundation
import IDeviceSwift
import NimbleExtensions

protocol DeviceIdentityVerifying: Sendable {
    func query(
        expectedIdentifier: String,
        fingerprint: String?,
        reporting: @escaping @Sendable (DeviceConnectionStage) -> Void
    ) async throws -> AuthorizedDeviceSnapshot
}

struct PairedDeviceIdentityVerifier: DeviceIdentityVerifying {
    func query(expectedIdentifier: String, fingerprint: String?,
               reporting: @escaping @Sendable (DeviceConnectionStage) -> Void) async throws -> AuthorizedDeviceSnapshot {
        try await PairingBridge.queryDevice(expectedIdentifier: expectedIdentifier,
                                            fingerprint: fingerprint, reporting: reporting)
    }
}

@MainActor
final class DeviceRegistryService {
    private let store: DeviceLifecycleStore
    private let verifier: any DeviceIdentityVerifying
    private let reporter: DeviceLifecycleTaskReporter
    private let diagnostics: DiagnosticRecorder

    init(store: DeviceLifecycleStore,
         verifier: any DeviceIdentityVerifying = PairedDeviceIdentityVerifier(),
         reporter: DeviceLifecycleTaskReporter,
         diagnostics: DiagnosticRecorder = .fileRecorder) {
        self.store = store
        self.verifier = verifier
        self.reporter = reporter
        self.diagnostics = diagnostics
    }

    func devices() async throws -> [ManagedDeviceRecord] {
        try await store.devices()
    }

    /// Records the pairing file as an available clue, never as a live connection. Previously
    /// connected rows without a matching record are demoted to remembered; their history is
    /// retained so a reconnect can be recognized.
    func refreshFromPairingRecord() async throws -> [ManagedDeviceRecord] {
        let review = try await PairingBridge.reviewRecord()
        let state = StoredPairingState.from(review.state)
        let pairingID = review.deviceIdentifier ?? review.fingerprint
        var records = try await store.devices()
        let now = Date()

        for index in records.indices where records[index].link != .remembered {
            let matches = pairingID.map { records[index].id == $0 || records[index].id.hasSuffix($0.suffix(8)) } ?? false
            if !matches || state == .absent {
                records[index].link = state == .absent ? .remembered : .unavailable
                if records[index].trust == .verified { records[index].trust = .unverified }
                records[index].updatedAt = now
            }
        }

        if state != .absent, let identity = ManagedDeviceRecord.identity(
            udid: review.deviceIdentifier, pairingFingerprint: review.fingerprint
        ) {
            let context = Self.capabilityContext(pairing: review.state, osVersion: .current)
            let capabilities = StoredDeviceCapability.from(DeviceCapabilityResolver.report(context))
            if let index = records.firstIndex(where: { $0.id == identity.id }) {
                records[index].pairing = state
                records[index].trust = records[index].trust == .verified ? .verified : .unverified
                records[index].capabilities = capabilities
                records[index].link = records[index].link == .connected ? .connected : .paired
                records[index].lastSeenAt = now
                records[index].updatedAt = now
            } else {
                records.append(ManagedDeviceRecord(
                    id: identity.id, hasStableIdentifier: identity.stable,
                    name: review.deviceIdentifier ?? .localized("Unnamed device"),
                    link: .paired, pairing: state, trust: .unverified,
                    capabilities: capabilities, lastSeenAt: now, updatedAt: now
                ))
            }
        }
        try await store.save(devices: records)
        return records
    }

    /// Opens one consented device query and promotes the record only when the device answers.
    /// The session closes inside the native verifier; nothing here claims an enduring link.
    @discardableResult
    func verify(deviceID: String) async throws -> ManagedDeviceRecord {
        guard PairingRecordDocument.isDeviceIdentifier(deviceID) else {
            throw DeviceLifecycleError.invalidIdentifier
        }
        let review = try await PairingBridge.reviewRecord()
        guard PairingBridge.protocolConsent else { throw DeviceTransportError.consentRequired }
        guard PairingBridge.canQuery(review.state, expectedIdentifier: deviceID) else {
            throw DeviceTransportError.expectedDeviceRequired
        }

        let subject = "device-verify." + deviceID
        guard let taskID = await reporter.beginOnce(
            kind: .deviceSetup, title: .localized("Verify paired device"),
            subtitle: .localized("Fresh identity-bound device query"), subjectID: subject
        ) else { throw DeviceLifecycleError.operationBlocked(
            .localized("A verification for this device is already running.")
        ) }

        do {
            let snapshot = try await verifier.query(expectedIdentifier: deviceID,
                                                    fingerprint: review.fingerprint) { stage in
                Task { @MainActor [weak reporter = self.reporter] in
                    await reporter?.report(stage: stage, for: taskID)
                }
            }
            try Task.checkCancellation()
            guard PairingRecordInspector.normalize(snapshot.deviceIdentifier) == deviceID else {
                throw DeviceTransportError.wrongDevice
            }
            let capabilities = StoredDeviceCapability.from(
                DeviceCapabilityResolver.report(Self.capabilityContext(
                    pairing: review.state,
                    osVersion: DeviceOSVersion.parse(snapshot.productVersion) ?? .current,
                    presence: .connected, trust: .verified, transportAvailable: true
                ))
            )
            let previous = try await store.device(id: deviceID)
            guard let record = ManagedDeviceRecord.from(
                snapshot: snapshot, pairing: StoredPairingState.from(review.state),
                capabilities: capabilities, previous: previous
            ) else { throw DeviceLifecycleError.invalidRecord }
            try await store.upsert(record)
            await reporter.transition(id: taskID, to: .completed)
            return record
        } catch {
            await reporter.transition(id: taskID,
                to: error is CancellationError ? .cancelled : .failed,
                error: error.localizedDescription)
            try await recordFailure(deviceID: deviceID, error: error)
            throw error
        }
    }

    func markUnavailable(deviceID: String, reason: String) async throws {
        guard var device = try await store.device(id: deviceID) else { return }
        if device.link == .connected { device.link = .unavailable }
        device.diagnostics.insert(
            DeviceDiagnostic(severity: .warning, code: "transport-unavailable",
                             message: LogRedaction.redact(reason)),
            at: 0
        )
        device.diagnostics = Array(device.diagnostics.prefix(ManagedDeviceRecord.maximumDiagnostics))
        device.updatedAt = Date()
        try await store.upsert(device)
    }

    func recordFailure(deviceID: String, error: Error) async throws {
        guard var device = try await store.device(id: deviceID) else { return }
        let cancelled = error is CancellationError || error as? DeviceTransportError == .operationCancelled
        let severity: DeviceDiagnostic.Severity = cancelled ? .info : .error
        let code: String
        switch error as? DeviceTransportError {
        case .permissionDenied: code = "device-untrusted"
        case .developerModeUnverified: code = "pairing-required"
        case .wrongDevice: code = "wrong-device"
        case .consentRequired: code = "consent-required"
        case .transportUnavailable, .connectionRefused, .transportTimeout: code = "transport-unavailable"
        default: code = "device-operation-failed"
        }
        switch error as? DeviceTransportError {
        case .permissionDenied: device.link = .untrusted
        case .developerModeUnverified: device.link = .pairingRequired
        case .transportUnavailable, .connectionRefused, .transportTimeout, .wrongDevice:
            device.link = .unavailable
        default: break
        }
        device.diagnostics.insert(
            DeviceDiagnostic(severity: severity, code: code, message: LogRedaction.redact(error.localizedDescription)),
            at: 0
        )
        device.diagnostics = Array(device.diagnostics.prefix(ManagedDeviceRecord.maximumDiagnostics))
        device.updatedAt = Date()
        try await store.upsert(device)
        if !cancelled {
            // The device UDID is deliberately not copied into the event: the
            // stable failure code and the correlated task event are enough to
            // diagnose a connection without carrying an identifier.
            await diagnostics.record(.make(
                code: DiagnosticEventCode.deviceFailure,
                severity: .error,
                category: .device,
                userMessage: "A device connection or lifecycle operation failed.",
                developerDetail: error.localizedDescription,
                recoverySuggestion: DiagnosticRecoveryGuide.suggestion(for: .deviceUnreachable),
                metadata: ["failureCode": code]
            ))
        }
    }

    func forget(deviceID: String) async throws {
        try await store.removeDevice(id: deviceID)
    }

    private static func capabilityContext(
        pairing: DevicePairingState,
        osVersion: DeviceOSVersion,
        presence: DevicePresence = .discovered,
        trust: DeviceTrust = .unverified,
        transportAvailable: Bool? = nil
    ) -> DeviceCapabilityContext {
        DeviceCapabilityContext(
            pairing: pairing,
            presence: presence,
            trust: trust,
            pairingTransportAvailable: transportAvailable
                ?? PairingBridge.canQuery(pairing, expectedIdentifier: pairing.udid ?? ""),
            companionAvailable: LocalTLSIdentity.isSystemTrusted(),
            osVersion: osVersion,
            inventoryBridgeAvailable: InstallationAppProxy.hasAcceptedInventoryBridge,
            onDeviceHostAvailable: PairingHostBridge.isSupported
        )
    }
}
