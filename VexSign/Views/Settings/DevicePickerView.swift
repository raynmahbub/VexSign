// MARK: - DevicePickerView
/// Device selection UI.
///
/// The picker describes the pairing record it holds and the capabilities that actually follow
/// from it. It does not claim a live connection it cannot observe, and it does not claim trust
/// because a file could be read — see `DeviceConnectivity.swift` for the states.

import SwiftUI
import NimbleViews
import NimbleExtensions
import IDeviceSwift
import os

struct DevicePickerView: View {
    @Binding var deviceIdentifier: String
    @Environment(\.dismiss) private var dismiss
    @State private var manualUDID = ""
    @State private var useManual = false
    @State private var pairedDevices: [PairedDeviceRecord] = []
    @State private var pairing: DevicePairingState = .absent
    @State private var isLoading = false
    /// Whether the pairing session's socket answered when this sheet opened. Observed, not
    /// assumed: it stays false until the probe says otherwise.
    @State private var pairingTransportAvailable = false
    @State private var selectedUDID: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(.localized("Enter UDID Manually"), isOn: $useManual)
                    if useManual {
                        TextField(.localized("UDID (40 hex chars or 25-char format)"), text: $manualUDID)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: manualUDID) { _, newValue in
                                // Auto-format: remove non-hex characters
                                let filtered = newValue.uppercased().filter { "0123456789ABCDEF-".contains($0) }
                                if filtered != newValue { manualUDID = filtered }
                            }
                    }
                } header: {
                    Text(.localized("Manual Entry"))
                } footer: {
                    Text(.localized("The UDID can be found in Settings → General → About, or via Xcode/Finder when device is connected. Format: 40 hex chars (legacy) or 8-16-16-16-16 (modern)."))
                }

                Section {
                    if isLoading {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(.localized("Loading paired devices…"))
                                .foregroundStyle(.secondary)
                        }
                    } else if pairedDevices.isEmpty {
                        pairingProblem
                    } else {
                        ForEach(pairedDevices) { device in
                            Button {
                                selectedUDID = device.udid
                            } label: {
                                deviceRow(device)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(.localized("Paired Devices"))
                } footer: {
                    Text(.localized("A pairing file describes one device: the one it was generated for. VexSign cannot enumerate other devices from inside the sandbox."))
                }

                if !pairedDevices.isEmpty {
                    capabilitySection
                }
            }
            .navigationTitle(.localized("Select Device"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.localized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(.localized("Done")) {
                        if useManual && !manualUDID.isEmpty {
                            deviceIdentifier = manualUDID
                        } else if let udid = selectedUDID {
                            deviceIdentifier = udid
                        }
                        dismiss()
                    }
                    .disabled((useManual && manualUDID.isEmpty) || (!useManual && selectedUDID == nil))
                }
            }
        }
        .task {
            await loadPairedDevices()
            // The probe blocks for up to its timeout, so it runs off the main actor.
            pairingTransportAvailable = await Task.detached(priority: .userInitiated) {
                HeartbeatManager.shared.checkSocketConnection().isConnected
            }.value
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Rows

    @ViewBuilder
    private func deviceRow(_ device: PairedDeviceRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(device.udid)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label(device.deviceType, systemImage: deviceTypeIcon(device.deviceType))
                    Label(device.iosVersion, systemImage: "iphone.gen3")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                // Presence and trust are separate claims: a row can be "device found" without
                // being able to say the device would accept this host.
                HStack(spacing: 6) {
                    Label(device.presence.title, systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Label(device.trust.title, systemImage: device.trust == .verified ? "checkmark.seal.fill" : "questionmark.circle")
                        .foregroundStyle(device.trust == .verified ? Color.green : Color.orange)
                }
                .font(.caption2)
            }
            Spacer()
            if selectedUDID == device.udid {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// What is wrong with the pairing record, named precisely.
    ///
    /// "No paired devices" used to be the only sentence, whether the file was missing, truncated
    /// or missing half its keys — three problems with three different fixes.
    @ViewBuilder
    private var pairingProblem: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(pairing.title, systemImage: pairing.isUsable ? "exclamationmark.triangle.fill" : "tray")
                .font(.subheadline)
                .foregroundStyle(pairing.isUsable ? Color.orange : Color.secondary)
            Text(pairing.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(.localized("Refresh")) {
                Task { await loadPairedDevices() }
            }
            .buttonStyle(.bordered)
        }
    }

    /// The same capability answers the install paths read, so a row cannot promise an operation
    /// the transport does not support.
    @ViewBuilder
    private var capabilitySection: some View {
        Section {
            ForEach(report.capabilities, id: \.operation.id) { capability in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(capability.operation.title)
                            .font(.subheadline)
                        Spacer()
                        Text(capability.status.title)
                            .font(.caption)
                            .foregroundStyle(color(for: capability.status))
                    }
                    Text(capability.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(.localized("Supported operations"))
        } footer: {
            Text(.localized("Determined from the pairing record, the pairing session and the installation service this build links, not from what a device might support in general."))
        }
    }

    private var report: DeviceCapabilityReport {
        DeviceCapabilityResolver.report(
            DeviceCapabilityContext(
                pairing: pairing,
                presence: pairedDevices.first?.presence ?? .disconnected,
                trust: pairedDevices.first?.trust ?? .unknown,
                pairingTransportAvailable: pairingTransportAvailable,
                companionAvailable: LocalTLSIdentity.current() != nil && LocalTLSIdentity.isSystemTrusted()
            )
        )
    }

    private func color(for status: DeviceCapabilityStatus) -> Color {
        switch status {
        case .supported: .green
        case .requiresCompanion, .requiresAuthorization, .requiresUserAction: .orange
        case .unsupported, .temporarilyUnavailable: .red
        case .unknown: .secondary
        }
    }

    private func deviceTypeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "iphone": return "iphone"
        case "ipad": return "ipad"
        case "ipod": return "ipodtouch"
        case "appletv": return "appletv"
        case "watch": return "applewatch"
        default: return "questionmark.circle"
        }
    }

    private func loadPairedDevices() async {
        isLoading = true
        defer { isLoading = false }

        let result = await IDeviceManager.shared.pairedDevices()
        pairing = result.pairing
        pairedDevices = result.devices
        if let selectedUDID, !pairedDevices.contains(where: { $0.udid == selectedUDID }) {
            self.selectedUDID = nil
        }

        // What this build can do with the record, written once per load so a support log can
        // answer "why did the paired install fail?" without a device in hand. No identifier is
        // included: `logLines` carries operation names and statuses only.
        for line in report.logLines {
            logger.debug("\(line, privacy: .public)")
        }
    }
}

// MARK: - IDeviceManager

/// Reads the pairing record and describes the device it names.
///
/// Not a device manager in the sense of owning sessions: the linked `IDevice` binary talks to one
/// device through the pairing record, and this type reads that record. Naming it after the
/// framework it wraps keeps the existing call sites intact.
@MainActor
final class IDeviceManager {
    static let shared = IDeviceManager()

    private init() {}

    /// Returns the path to the pairing file
    private var pairingFilePath: String {
        HeartbeatManager.pairingFile()
    }

    struct Result: Sendable {
        let pairing: DevicePairingState
        let devices: [PairedDeviceRecord]
    }

    /// One record per device, with the pairing state that produced it.
    ///
    /// Duplicate records collapse by UDID, so importing the same pairing file twice — or reading
    /// it in two formats — cannot produce two rows for one device.
    func pairedDevices() async -> Result {
        let url = URL(fileURLWithPath: pairingFilePath)
        let pairing = PairingRecordInspector.inspect(fileAt: url)

        guard let udid = pairing.udid else {
            return Result(pairing: pairing, devices: [])
        }

        let info = await queryDeviceInfo()

        // Presence is "found", not "connected": the record is the only evidence available from
        // inside the sandbox, and the capability report says what still has to happen.
        let record = PairedDeviceRecord(
            udid: udid,
            name: info?.name ?? .localized("iOS Device"),
            deviceType: info?.deviceType ?? .localized("iPhone"),
            iosVersion: info?.iosVersion ?? .localized("Unknown"),
            presence: .discovered,
            pairing: pairing,
            trust: info?.trust ?? .unverified
        )

        return Result(pairing: pairing, devices: PairedDeviceRecord.unique([record]))
    }

    /// Device details through `LockdownClient`.
    ///
    /// This reads the record and the running system. It does not open a device session, which is
    /// why the answer it returns can never raise trust.
    private func queryDeviceInfo() async -> DeviceInfo? {
        let pairingFileURL = URL(fileURLWithPath: pairingFilePath)
        guard FileManager.default.fileExists(atPath: pairingFilePath) else { return nil }

        do {
            let client = LockdownClient(pairingFileURL: pairingFileURL)
            try await client.connect()
            let info = try await client.getDeviceInfo()
            await client.disconnect()
            return info
        } catch {
            logger.debug("Failed to query device info: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

private let logger = Logger(subsystem: "com.vexsign", category: "DevicePicker")
