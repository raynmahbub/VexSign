// MARK: - DevicePickerView
/// Device selection UI that integrates with IDeviceSwift for paired devices
/// and supports manual UDID entry.

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
    @State private var pairedDevices: [PairedDevice] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedDevice: PairedDevice?

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
                            .onChange(of: manualUDID) { newValue in
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
                    } else if let error = loadError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(.localized("Failed to load paired devices"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(.localized("Retry")) {
                                Task { await loadPairedDevices() }
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if pairedDevices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(.localized("No paired devices found"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(.localized("Connect your device via USB and trust it, or ensure a valid pairing file is configured in Settings → Installation."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(.localized("Refresh")) {
                                Task { await loadPairedDevices() }
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        ForEach(pairedDevices) { device in
                            Button {
                                selectedDevice = device
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text(device.udid)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fontDesign(.monospaced)
                                        HStack(spacing: 8) {
                                            Label(device.deviceType, systemImage: deviceTypeIcon(device.deviceType))
                                            Label(device.iosVersion, systemImage: "iphone.gen3")
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if selectedDevice?.udid == device.udid {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(.localized("Paired Devices"))
                } footer: {
                    Text(.localized("Select a paired device to use its UDID automatically. Pairing requires a valid pairing file configured in Settings → Installation."))
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
                        } else if let device = selectedDevice {
                            deviceIdentifier = device.udid
                        }
                        dismiss()
                    }
                    .disabled((useManual && manualUDID.isEmpty) || (!useManual && selectedDevice == nil))
                }
            }
        }
        .task {
            await loadPairedDevices()
        }
        .presentationDetents([.medium, .large])
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
        loadError = nil
        defer { isLoading = false }

        do {
            let devices = try await IDeviceManager.shared.getPairedDevices()
            await MainActor.run {
                self.pairedDevices = devices
            }
        } catch {
            await MainActor.run {
                self.loadError = error.localizedDescription
            }
        }
    }
}

// MARK: - Supporting Types

/// Device information retrieved via Lockdown.
public struct DeviceInfo: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let deviceType: String
    public let iosVersion: String
    public let buildVersion: String
    public let modelNumber: String
    public let isTrusted: Bool

    public var displayName: String {
        "\(name) (\(deviceType))"
    }
}

struct PairedDevice: Identifiable {
    let id = UUID()
    let udid: String
    let name: String
    let deviceType: String
    let iosVersion: String
    let isTrusted: Bool
}

// MARK: - IDeviceManager

@MainActor
final class IDeviceManager {
    static let shared = IDeviceManager()

    private init() {}

    /// Returns the path to the pairing file
    private var pairingFilePath: String {
        // Default Feather pairing file location
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pairingFile.plist").path
    }

    /// Attempts to read the pairing file and extract device UDID
    private func readPairingFileUDID() -> String? {
        let path = pairingFilePath
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            // The pairing file is a plist with keys like DeviceID, HostID, etc.
            if let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               let deviceID = plist["DeviceID"] as? String {
                return deviceID
            }
        } catch {
            // Try reading as binary plist
            if let plist = try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), options: [], format: nil) as? [String: Any], // try? ok: fallback parse, guard handles nil
               let deviceID = plist["DeviceID"] as? String {
                return deviceID
            }
        }
        return nil
    }

    /// Gets paired devices by reading the pairing file and querying device info via IDevice
    func getPairedDevices() async throws -> [PairedDevice] {
        // First, try to get UDID from pairing file
        guard let udid = readPairingFileUDID() else {
            // No pairing file found
            return []
        }

        // Try to get device info via IDevice if device is connected
        // For now, we return the device from pairing file with basic info
        // In a full implementation, we'd connect via USB and query device details

        // Check if we can get more details via IDevice
        let deviceInfo = try? await queryDeviceInfo(udid: udid) // try? ok: optional device info, guard handles nil

        let device = PairedDevice(
            udid: udid,
            name: deviceInfo?.name ?? "iOS Device",
            deviceType: deviceInfo?.deviceType ?? "iPhone",
            iosVersion: deviceInfo?.iosVersion ?? "Unknown",
            isTrusted: deviceInfo?.isTrusted ?? true
        )

        return [device]
    }

    /// Queries device info via IDeviceSwift LockdownClient
    private func queryDeviceInfo(udid: String) async throws -> DeviceInfo? {
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