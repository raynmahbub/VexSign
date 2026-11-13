//
//  LocationSimulatorSettingsView.swift
//  VexSign — Location Simulator & GPS Controls
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct LocationSimulatorSettingsView: View {
    @AppStorage("VexSign.location.enabled") private var isSimulating = false
    @AppStorage("VexSign.location.latitude") private var latitude: Double = 37.3349
    @AppStorage("VexSign.location.longitude") private var longitude: Double = -122.0090
    @AppStorage("VexSign.location.presetName") private var presetName: String = "Apple Park (Cupertino)"
    @AppStorage("VexSign.location.speed") private var speedMode: String = "Walking (5 km/h)"

    private let presets: [(name: String, lat: Double, lon: Double)] = [
        ("Apple Park (Cupertino)", 37.3349, -122.0090),
        ("Times Square (New York)", 40.7580, -73.9855),
        ("Shibuya Crossing (Tokyo)", 35.6595, 139.7005),
        ("Big Ben (London)", 51.5007, -0.1246),
        ("Sydney Opera House (Sydney)", -33.8568, 151.2153),
        ("Eiffel Tower (Paris)", 48.8584, 2.2945)
    ]

    private let speedOptions = ["Stationary (0 km/h)", "Walking (5 km/h)", "Cycling (20 km/h)", "Driving (60 km/h)"]

    var body: some View {
        NBList(.localized("Location Simulator")) {
            statusSection

            presetsSection

            customCoordinatesSection

            movementSimulationSection
        }
    }

    private var statusSection: some View {
        NBSection(.localized("Simulation Status")) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((isSimulating ? Color.blue : Color.secondary).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: isSimulating ? "location.fill" : "location.slash.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isSimulating ? Color.blue : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(.localized("Location Spoofer"))
                            .font(.headline)
                        Text(isSimulating ? .localized("ACTIVE") : .localized("INACTIVE"))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(isSimulating ? Color.blue : Color.secondary, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Text(isSimulating ? "\(presetName) • \(String(format: "%.4f, %.4f", latitude, longitude))" : .localized("Device reports real hardware GPS coordinates."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)

            Toggle(.localized("Enable Location Simulation"), isOn: $isSimulating)
                .tint(Color.blue)
        } footer: {
            Text(.localized("Emulates on-device CoreLocation coordinates via developer disk image services without jailbreak."))
        }
    }

    private var presetsSection: some View {
        NBSection(.localized("Quick Presets")) {
            ForEach(presets, id: \.name) { item in
                Button {
                    latitude = item.lat
                    longitude = item.lon
                    presetName = item.name
                    NBHaptic.selection()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.primary)
                            Text(String(format: "Lat: %.4f, Lon: %.4f", item.lat, item.lon))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if presetName == item.name {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var customCoordinatesSection: some View {
        NBSection(.localized("Custom Coordinates")) {
            HStack {
                Text(.localized("Latitude"))
                Spacer()
                Text(String(format: "%.6f", latitude))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Text(.localized("Longitude"))
                Spacer()
                Text(String(format: "%.6f", longitude))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } footer: {
            Text(.localized("Enter specific coordinates to spoof within geo-restricted or regional applications."))
        }
    }

    private var movementSimulationSection: some View {
        NBSection(.localized("Movement & Speed")) {
            Picker(.localized("Speed Mode"), selection: $speedMode) {
                ForEach(speedOptions, id: \.self) { opt in
                    Text(opt).tag(opt)
                }
            }
            .pickerStyle(.menu)
        } footer: {
            Text(.localized("Simulates natural drift and speed variations to avoid instant teleportation bans in location-sensitive apps."))
        }
    }
}
