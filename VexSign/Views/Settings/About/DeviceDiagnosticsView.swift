//
//  DeviceDiagnosticsView.swift
//  VexSign — System Diagnostics
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct DeviceDiagnosticsView: View {
    @State private var diagnosticReportString = ""

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
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)
    }

    private var availableDiskSpace: String {
        let avail = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .file)
    }

    var body: some View {
        NBList(.localized("System Diagnostics")) {
            overviewSection

            hardwareSection

            firmwareSection

            storageSection

            exportSection
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
            LabeledContent(.localized("Developer Mode"), value: String.localized("Enabled"))
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
                generateReport()
                UIActivityViewController.show(activityItems: [diagnosticReportString])
            } label: {
                Label(.localized("Share Diagnostic Report"), systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text(.localized("Exports a comprehensive diagnostic log for bug reports, developer support, or certificate troubleshooting."))
        }
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
        Certificates Installed: \(Storage.shared.getAllCertificates().count)
        Signed Apps: \(Storage.shared.getSignedApps().count)
        Imported Apps: \(Storage.shared.getImportedApps().count)
        Sources Configured: \(Storage.shared.getSources().count)
        Time: \(Date())
        ========================================
        """
    }
}
