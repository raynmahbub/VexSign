//
//  LocationSimulatorSettingsView.swift
//  VexSign — Location Simulator Capability Notice
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct LocationSimulatorSettingsView: View {
    var body: some View {
        NBList(.localized("Location Simulator")) {
            statusSection
            technicalDetailsSection
            relatedToolsSection
        }
        .onAppear {
            clearLegacyFakePreferences()
        }
    }

    private var statusSection: some View {
        NBSection(.localized("Availability")) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(.localized("Location Simulator"))
                            .font(.headline)
                        Text(.localized("UNAVAILABLE"))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.secondary, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Text(.localized("System-wide GPS simulation is not supported in this on-device build."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text(.localized("VexSign never alters device GPS coordinates. Your device always reports real system location to iOS and installed apps."))
        }
    }

    private var technicalDetailsSection: some View {
        NBSection(.localized("Why It Is Unavailable")) {
            LabeledContent(
                .localized("Sandboxed CoreLocation"),
                value: String.localized("Blocked by iOS")
            )
            LabeledContent(
                .localized("DDI Location Service"),
                value: String.localized("Not Present in Transport")
            )
        } footer: {
            Text(.localized("Simulating system GPS requires a mounted Developer Disk Image and DVT/RSD location simulation service over a trusted tunnel or USB tether. VexSign's linked device transport provides Heartbeat and InstallationProxy only."))
        }
    }

    private var relatedToolsSection: some View {
        NBSection(.localized("Supported Device Tools")) {
            NavigationLink(destination: InstallationView()) {
                Label(.localized("Installation Engine & Pairing"), systemImage: "arrow.down.app")
            }
            NavigationLink(destination: FeatureStatusView()) {
                Label(.localized("Feature Status Registry"), systemImage: "checklist")
            }
        }
    }

    private func clearLegacyFakePreferences() {
        for key in [
            "VexSign.location.enabled",
            "VexSign.location.latitude",
            "VexSign.location.longitude",
            "VexSign.location.presetName",
            "VexSign.location.speed"
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
