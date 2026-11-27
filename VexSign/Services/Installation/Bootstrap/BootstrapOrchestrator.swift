// Guided computer-free bootstrap coordinator.
//
// The state machine lives in BootstrapJourney. This coordinator only drives the
// two steps VexSign can perform itself on iOS 27+ (RPPairing host + a fresh
// device identity query) through the existing PairingHostBridge/PairingBridge
// owners. Account, signing and installation evidence is handed in by the
// existing feature flows via recordHandoff(_:), never invented here.

import Foundation
import Combine
import IDeviceSwift
import NimbleExtensions

enum BootstrapPhase: String, CaseIterable, Hashable, Sendable {
    case idle
    case checkingEnvironment
    case preparingPairing
    case pairing
    case verifyingPairing
    case authenticating
    case provisioning
    case validatingIPA
    case signing
    case verifyingSignature
    case installing
    case confirmingInstallation
    case verifyingLaunch
    case completed
    case failed
    case cancelled
}

struct BootstrapStateSnapshot: Sendable {
    let phase: BootstrapPhase
    let message: String
    let pin: String?
    let error: String?
}

private struct BootstrapStepFailure: LocalizedError {
    let rejection: BootstrapRejection
    var errorDescription: String? { rejection.errorDescription }
}

@MainActor
final class BootstrapOrchestrator: ObservableObject {
    @Published private(set) var phase: BootstrapPhase = .idle
    @Published private(set) var message: String = ""
    @Published private(set) var pin: String?
    @Published private(set) var error: String?
    @Published private(set) var capability: BootstrapCapability
    @Published private(set) var journey: BootstrapJourney

    private let expectedBundleIdentifier: String
    private let expectedVersion: String?
    private var deviceIdentifier: String?
    private var cancelled = false
    private var pairingBridge: PairingHostBridge?

    init(expectedBundleID: String = Bundle.main.bundleIdentifier ?? "",
         expectedVersion: String? = nil,
         capability: BootstrapCapability? = nil) {
        var simulator = false
        #if targetEnvironment(simulator)
        simulator = true
        #endif
        let resolved = capability ?? BootstrapCapability(
            osVersion: .current,
            hostAvailable: PairingHostBridge.isSupported,
            isSimulator: simulator,
            pairedInstallationAccepted: PairingBridge.pairedInventoryAccepted
        )
        self.capability = resolved
        self.expectedBundleIdentifier = expectedBundleID
        self.expectedVersion = expectedVersion
        self.journey = BootstrapJourney(
            expectedBundleIdentifier: expectedBundleID,
            expectedVersion: expectedVersion
        )
    }

    var stateSnapshot: BootstrapStateSnapshot {
        BootstrapStateSnapshot(phase: phase, message: message, pin: pin, error: error)
    }

    var canStart: Bool { capability.canStartComputerFreePairing && !journey.isComplete }

    func cancel() {
        cancelled = true
        pairingBridge?.cancel()
        pin = nil
        phase = .cancelled
        message = .localized("Bootstrap cancelled. No device authorization or installation is claimed.")
    }

    func reset() {
        cancelled = false
        pairingBridge = nil
        phase = .idle
        message = ""
        pin = nil
        error = nil
        deviceIdentifier = nil
        journey.reset()
    }

    /// Runs only the two native steps of the journey. A successful return stops
    /// at account handoff; it never reports a signed or installed application.
    func runOnDeviceBootstrap(expectedDeviceIdentifier: String? = nil) async {
        reset()
        guard capability.canStartComputerFreePairing else {
            fail(capability.blockers.first?.detail
                 ?? DeviceTransportError.hostUnavailable.localizedDescription)
            return
        }
        deviceIdentifier = expectedDeviceIdentifier
        switch journey.record(.environment(route: capability.route, simulator: capability.isSimulator)) {
        case .rejected(let reason):
            fail(reason.errorDescription)
            return
        case .accepted:
            break
        }
        do {
            try await stepPairing()
            try await stepVerifyPairing()
            phase = .authenticating
            message = .localized("Pairing and device identity are verified. Finish account authorization in Accounts, then sign and install the IPA in Library. No installation is claimed by this guide.")
        } catch is CancellationError {
            cancel()
        } catch {
            // The host reports an explicit cancellation as a typed native error.
            // Keep the cancelled outcome; do not relabel it as a generic failure.
            if cancelled {
                cancel()
            } else {
                fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Re-runs the native steps from a fresh journey while keeping the device
    /// the user already selected. Used after cancellation or a failed query.
    func retry() async {
        let selected = deviceIdentifier
        reset()
        deviceIdentifier = selected
        await runOnDeviceBootstrap(expectedDeviceIdentifier: selected)
    }

    /// Called by the existing account/signing/installation flows when they
    /// actually produce evidence. Events out of order or with mismatched
    /// identity are rejected; no step is completed by a navigation action.
    func recordHandoff(_ event: BootstrapEvent) {
        switch event.step {
        case .environment, .pairing, .verification:
            error = BootstrapRejection.outOfOrder.errorDescription
            return
        case .account:
            phase = .authenticating
        case .artifact:
            phase = .validatingIPA
        case .signing:
            phase = .signing
        case .installation:
            phase = .installing
        case .confirmation:
            phase = .confirmingInstallation
        }
        switch journey.record(event) {
        case .accepted(let step):
            error = nil
            message = .localized("Recorded: %@", arguments: step.title)
            if journey.isComplete {
                phase = .completed
                message = .localized("Bootstrap evidence is complete for this artifact and device. Check the Home Screen to confirm the launch.")
            }
        case .rejected(let reason):
            fail(reason.errorDescription)
        }
    }

    private func stepPairing() async throws {
        guard !cancelled else { throw CancellationError() }
        phase = .preparingPairing
        message = .localized("Preparing the on-device pairing host…")
        let bridge = PairingHostBridge()
        pairingBridge = bridge
        defer { pairingBridge = nil }
        phase = .pairing
        let enrollment = try await bridge.startOnDevicePairing(replacing: nil) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.message = progress.stage
                self.pin = progress.pin
            }
        }
        try Task.checkCancellation()
        // The returned metadata describes what the bridge installed. Re-read the
        // protected store before treating it as evidence for the next step.
        let stored = try await PairingBridge.reviewRecord()
        guard stored.fingerprint == enrollment.metadata.sha256,
              stored.format == enrollment.metadata.format else {
            throw DeviceTransportError.invalidDeviceResponse
        }
        let result = journey.record(
            .pairing(format: enrollment.metadata.format, fingerprint: enrollment.metadata.sha256)
        )
        if case .rejected(let reason) = result { throw BootstrapStepFailure(rejection: reason) }
        pin = nil
    }

    private func stepVerifyPairing() async throws {
        guard !cancelled else { throw CancellationError() }
        guard PairingBridge.protocolConsent else { throw DeviceTransportError.consentRequired }
        guard let selected = deviceIdentifier,
              PairingRecordDocument.isDeviceIdentifier(
                  PairingRecordDocument.normalizeDeviceIdentifier(selected)
              ) else { throw DeviceTransportError.expectedDeviceRequired }
        phase = .verifyingPairing
        message = .localized("Querying the selected device with the new pairing record…")
        let snapshot = try await PairingBridge.queryDevice(
            expectedIdentifier: selected,
            fingerprint: journey.evidence.pairingFingerprint,
            reporting: { _ in }
        )
        try Task.checkCancellation()
        guard PairingRecordDocument.normalizeDeviceIdentifier(snapshot.deviceIdentifier)
                == PairingRecordDocument.normalizeDeviceIdentifier(selected) else {
            throw DeviceTransportError.wrongDevice
        }
        let result = journey.record(.verified(
            deviceIdentifier: snapshot.deviceIdentifier,
            productVersion: snapshot.productVersion,
            pairingFingerprint: snapshot.pairingSHA256
        ))
        if case .rejected(let reason) = result { throw BootstrapStepFailure(rejection: reason) }
    }

    private func fail(_ reason: String?) {
        phase = .failed
        error = reason ?? String.localized("Bootstrap failed. No device success is claimed.")
        message = error ?? ""
    }
}
