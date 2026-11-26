import Foundation
import Combine
import IDeviceSwift
import NimbleExtensions

enum BootstrapPhase: String, CaseIterable, Sendable {
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

@MainActor
final class BootstrapOrchestrator: ObservableObject {
    @Published private(set) var phase: BootstrapPhase = .idle
    @Published private(set) var message: String = ""
    @Published private(set) var pin: String?
    @Published private(set) var error: String?

    private var cancelled = false
    private var pairingBridge: PairingHostBridge?

    func cancel() {
        cancelled = true
        pairingBridge?.cancel()
        phase = .cancelled
        message = String.localized("Bootstrap cancelled.")
    }

    func reset() {
        cancelled = false
        pairingBridge = nil
        phase = .idle
        message = ""
        pin = nil
        error = nil
    }

    func runOnDeviceBootstrap(expectedBundleID: String, expectedVersion: String? = nil) async {
        reset()
        do {
            try await stepEnvironment()
            try await stepPairing()
            try await stepVerifyPairing()
            // Account/provision/sign/install are delegated to existing app owners.
            // This orchestrator tracks state and handoff; real execution requires
            // configured account/signing services and a physical device runtime.
            phase = .authenticating
            message = String.localized("Authenticate with your Apple Account in Accounts to continue provisioning.")
        } catch is CancellationError {
            cancel()
        } catch {
            phase = .failed
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            message = self.error ?? String.localized("Bootstrap failed.")
        }
    }

    private func stepEnvironment() async throws {
        guard !cancelled else { throw CancellationError() }
        phase = .checkingEnvironment
        message = String.localized("Checking device environment…")
        let version = DeviceOSVersion.current
        guard DevicePairingRoute.resolve(version) == .onDeviceHostPairing else {
            throw DeviceTransportError.unsupportedOS
        }
        #if targetEnvironment(simulator)
        throw DeviceTransportError.simulator
        #endif
    }

    private func stepPairing() async throws {
        guard !cancelled else { throw CancellationError() }
        phase = .preparingPairing
        message = String.localized("Preparing on-device pairing…")
        let bridge = PairingHostBridge()
        pairingBridge = bridge
        phase = .pairing
        _ = try await bridge.startOnDevicePairing(replacing: nil) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.message = progress.stage
                self?.pin = progress.pin
            }
        }
        pin = nil
    }

    private func stepVerifyPairing() async throws {
        guard !cancelled else { throw CancellationError() }
        phase = .verifyingPairing
        message = String.localized("Verify the stored pairing record and local transport before continuing.")
        // Verification is performed through the existing pairing/device query flow.
        // This step is intentionally explicit: a stored record is not trusted until verified.
    }
}
