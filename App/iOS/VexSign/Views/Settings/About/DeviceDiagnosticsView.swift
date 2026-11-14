//
//  DeviceDiagnosticsView.swift
//  VexSign — System Diagnostics
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct DeviceDiagnosticsView: View {
    @State private var diagnosticReportString = ""
    @State private var pairingState: DevicePairingState = PairingBridge.inspectPairingRecord()
    @State private var tlsIdentitySummary: String = LocalTLSIdentity.current()?.detail ?? String.localized("Not initialized")

    private var deviceModel: String {
        MobileGestalt.physicalHardwareName ?? UIDevice.current.model
    }

    private var iosVersion: String {
        UIDevice.current.systemVersion
    }

    private var buildNumber: String {
        MobileGestalt.buildVersion ?? "Unknown"
    }

    private var architecture: String {
        #if arch(arm64)
        return "arm64 / arm64e"
        #elseif arch(x86_64)
        return "x86_64 (Simulator)"
        #else
        return "Unknown"
        #endif
    }

    private var totalDiskSpace: String {
        ByteCountFormatter.string(fromByteCount: volumeCapacity(for: .volumeTotalCapacityKey), countStyle: .file)
    }

    private var availableDiskSpace: String {
        ByteCountFormatter.string(fromByteCount: volumeCapacity(for: .volumeAvailableCapacityKey), countStyle: .file)
    }

    var body: some View {
        NBList(.localized("System Diagnostics")) {
            overviewSection

            hardwareSection

            firmwareSection

            signingReadinessSection

            storageSection

            exportSection
        }
        .onAppear {
            refreshLocalDiagnostics()
        }
    }

    private var overviewSection: some View {
        NBSection(.localized("Hardware Profile")) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.userTint.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.userTint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(deviceModel)
                        .font(.headline)
                    Text("iOS \(iosVersion) (\(buildNumber)) • \(architecture)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var hardwareSection: some View {
        NBSection(.localized("Hardware & CPU")) {
            LabeledContent(.localized("Model"), value: deviceModel)
            LabeledContent(.localized("Architecture"), value: architecture)
            LabeledContent(.localized("Interface Idiom"), value: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
        }
    }

    private var firmwareSection: some View {
        NBSection(.localized("Operating System")) {
            LabeledContent(.localized("iOS Version"), value: iosVersion)
            LabeledContent(.localized("Build Number"), value: buildNumber)
            LabeledContent(.localized("Developer Mode"), value: String.localized("Check in iOS Settings"))
        } footer: {
            Text(.localized("iOS does not expose Developer Mode state to sandboxed apps. Verify it in iOS Settings → Privacy & Security if prompted during installation."))
        }
    }

    private var signingReadinessSection: some View {
        NBSection(.localized("Signing & Transport State")) {
            LabeledContent(.localized("App Routing"), value: SigningModeManager.shared.preference.title)
            LabeledContent(.localized("Pairing Record"), value: pairingState.title)
            LabeledContent(.localized("Local HTTPS Identity"), value: tlsIdentitySummary)
        }
    }

    private var storageSection: some View {
        NBSection(.localized("Storage Allocation")) {
            LabeledContent(.localized("Total Capacity"), value: totalDiskSpace)
            LabeledContent(.localized("Available Space"), value: availableDiskSpace)
        }
    }

    private var exportSection: some View {
        NBSection(.localized("Diagnostics Export")) {
            Button {
                refreshLocalDiagnostics()
                generateReport()
                UIActivityViewController.show(activityItems: [diagnosticReportString])
            } label: {
                Label(.localized("Share Diagnostic Report"), systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text(.localized("Exports a comprehensive diagnostic log for bug reports, developer support, or certificate troubleshooting."))
        }
    }

    private func volumeCapacity(for key: URLResourceKey) -> Int64 {
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [key])
            switch key {
            case .volumeTotalCapacityKey:
                return Int64(values.volumeTotalCapacity ?? 0)
            case .volumeAvailableCapacityKey:
                return Int64(values.volumeAvailableCapacity ?? 0)
            default:
                return 0
            }
        } catch {
            FileLogger.warn("Failed to read volume metadata (\(key.rawValue)): \(error.localizedDescription)", category: "diagnostics")
            return 0
        }
    }

    private func refreshLocalDiagnostics() {
        pairingState = PairingBridge.inspectPairingRecord()
        tlsIdentitySummary = LocalTLSIdentity.current()?.detail ?? String.localized("Not initialized")
    }

    private func generateReport() {
        diagnosticReportString = """
        === VexSign System Diagnostics Report ===
        Device Model: \(deviceModel)
        Architecture: \(architecture)
        iOS Version: \(iosVersion) (Build \(buildNumber))
        App Version: \(Bundle.main.version)
        Total Storage: \(totalDiskSpace)
        Available Storage: \(availableDiskSpace)
        App Routing Preference: \(SigningModeManager.shared.preference.rawValue)
        Pairing Record State: \(pairingState.title)
        Local HTTPS Identity: \(tlsIdentitySummary)
        Certificates Installed: \(Storage.shared.getAllCertificates().count)
        Signed Apps: \(Storage.shared.getSignedApps().count)
        Imported Apps: \(Storage.shared.getImportedApps().count)
        Sources Configured: \(Storage.shared.getSources().count)
        Time: \(Date())
        ========================================
        """
    }
}
