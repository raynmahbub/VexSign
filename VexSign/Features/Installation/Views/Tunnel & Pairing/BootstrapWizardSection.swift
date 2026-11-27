// Guided Phase 1 bootstrap. It owns no native handle: the coordinator uses the
// existing RPPairing host, pairing store and device query owners, and the
// account/signing/installation handoffs stay in their existing features.
import SwiftUI
import NimbleViews
import NimbleExtensions

struct BootstrapWizardSection: View {
    @Binding var deviceIdentifier: String
    /// Advances the advanced pairing panel so both panels read the same store.
    var pairingDidChange: () -> Void = {}
    @StateObject private var orchestrator = BootstrapOrchestrator()

    init(deviceIdentifier: Binding<String>, pairingDidChange: @escaping () -> Void = {}) {
        self._deviceIdentifier = deviceIdentifier
        self.pairingDidChange = pairingDidChange
    }

    private var isRunning: Bool {
        switch orchestrator.phase {
        case .preparingPairing, .pairing, .verifyingPairing:
            return true
        default:
            return false
        }
    }

    private func start() async {
        await orchestrator.runOnDeviceBootstrap(expectedDeviceIdentifier: deviceIdentifier)
        pairingDidChange()
    }

    private func restart() async {
        await orchestrator.retry()
        pairingDidChange()
    }

    var body: some View {
        Section {
            Label(orchestrator.capability.route.title, systemImage: "cable.connector")
            ForEach(orchestrator.capability.blockers, id: \.self) { blocker in
                Text(blocker.detail).font(.footnote).foregroundStyle(.secondary)
            }

            ForEach(BootstrapStep.allCases, id: \.self) { step in
                HStack(spacing: 10) {
                    Image(systemName: orchestrator.journey.completed.contains(step)
                          ? "checkmark.circle.fill" : "circle")
                    Text(step.title)
                        .fontWeight(orchestrator.journey.nextStep == step ? .semibold : .regular)
                    Spacer()
                    if let receipt = orchestrator.journey.evidence.receipt,
                       step == .confirmation {
                        Text(receipt).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.footnote)
            }

            if let pin = orchestrator.pin {
                VStack(alignment: .leading, spacing: 6) {
                    Text(.localized("Pairing PIN")).font(.caption).foregroundStyle(.secondary)
                    Text(pin).font(.system(.title2, design: .monospaced)).fontWeight(.semibold)
                    Text(.localized("Enter this PIN in Settings. The PIN is never stored in the bootstrap record."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if orchestrator.capability.canStartComputerFreePairing {
                TextField(.localized("Intended device UDID"), text: $deviceIdentifier)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.caption.monospaced()).privacySensitive().disabled(isRunning)
                if isRunning {
                    Button(.localized("Cancel bootstrap"), role: .cancel) {
                        orchestrator.cancel()
                    }
                } else if orchestrator.journey.isComplete {
                    Button(.localized("Restart bootstrap"), systemImage: "arrow.clockwise") {
                        Task { await restart() }
                    }
                } else if orchestrator.phase == .failed || orchestrator.phase == .cancelled {
                    Button(.localized("Retry bootstrap"), systemImage: "arrow.clockwise") {
                        Task { await restart() }
                    }
                } else {
                    Button(.localized("Start on-device bootstrap"), systemImage: "antenna.radiowaves.left.and.right") {
                        Task { await start() }
                    }
                    .disabled(deviceIdentifier.isEmpty)
                }
            }

            if !orchestrator.message.isEmpty {
                Text(orchestrator.message).font(.footnote).textSelection(.enabled)
            }
            if let failure = orchestrator.error {
                Text(failure).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
            }

            NavigationLink(destination: ProvisioningFlowView()) {
                Label(.localized("Authorize Apple Account or certificate"), systemImage: "person.badge.key")
            }
            NavigationLink(destination: LibraryView()) {
                Label(.localized("Choose an IPA and continue in Library"), systemImage: "shippingbox")
            }
        } header: {
            Text(.localized("Guided computer-free bootstrap"))
        } footer: {
            Text(.localized("This guide records evidence from the existing pairing, account, signing and installation owners. A verified device, a signed IPA and an accepted install request are separate outcomes; only a device-confirmed app at the expected version completes the journey. The first installation of VexSign itself still requires an eligible external installer."))
                .font(.footnote)
        }
    }
}
