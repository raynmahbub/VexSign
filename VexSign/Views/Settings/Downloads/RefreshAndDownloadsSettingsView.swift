//
//  RefreshAndDownloadsSettingsView.swift
//  VexSign — Refresh & Downloads Settings
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct RefreshAndDownloadsSettingsView: View {
    @AppStorage("VexSign.bgRefreshEnabled") private var bgRefreshEnabled: Bool = true
    @AppStorage("VexSign.autoCheckAppUpdates") private var autoCheckAppUpdates: Bool = true
    @AppStorage("VexSign.refreshIntervalString") private var refreshInterval: String = "1h"
    @AppStorage("VexSign.refreshNetworkOption") private var refreshNetworkOption: String = "Wi-Fi & Cellular"
    @AppStorage("VexSign.downloadsNetworkOption") private var downloadsNetworkOption: String = "Wi-Fi & Cellular"

    private let intervals = ["15m", "30m", "1h", "2h", "6h", "12h", "24h"]
    private let networkOptions = ["Wi-Fi", "Cellular", "Wi-Fi & Cellular"]

    private func networkTitle(_ opt: String) -> String {
        switch opt {
        case "Wi-Fi": return .localized("Wi-Fi")
        case "Cellular": return .localized("Cellular")
        case "Wi-Fi & Cellular": return .localized("Wi-Fi & Cellular")
        default: return opt
        }
    }

    private func intervalTitle(_ token: String) -> String {
        switch token {
        case "15m": return .localized("%lldm", arguments: 15)
        case "30m": return .localized("%lldm", arguments: 30)
        case "1h": return .localized("%lldh", arguments: 1)
        case "2h": return .localized("%lldh", arguments: 2)
        case "6h": return .localized("%lldh", arguments: 6)
        case "12h": return .localized("%lldh", arguments: 12)
        case "24h": return .localized("%lldh", arguments: 24)
        default: return token
        }
    }

    var body: some View {
        NBList(.localized("Refresh & Downloads")) {
            // MARK: - Background Refresh
            NBSection(.localized("BACKGROUND REFRESH")) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.pink.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.pink)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("iOS Background Refresh"))
                            .font(.subheadline.weight(.semibold))
                        Text(bgRefreshEnabled ? .localized("Enabled") : .localized("Disabled"))
                            .font(.caption2)
                            .foregroundStyle(bgRefreshEnabled ? .purple : .secondary)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Circle()
                            .fill(bgRefreshEnabled ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(bgRefreshEnabled ? .localized("ON") : .localized("OFF"))
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(bgRefreshEnabled ? Color.green : .secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(bgRefreshEnabled ? Color.green.opacity(0.12) : Color.secondary.opacity(0.12), in: Capsule())
                }
                .padding(.vertical, 2)

                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.red)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("App Updates"))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("Automatically check for updates"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $autoCheckAppUpdates)
                        .labelsHidden()
                        .tint(Color.red)
                }
                .padding(.vertical, 2)
            }

            // MARK: - Refresh Interval
            NBSection(.localized("REFRESH INTERVAL")) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.purple.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.purple)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Refresh Every"))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("Check for updates periodically"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Menu {
                        Picker(.localized("Interval"), selection: $refreshInterval) {
                            ForEach(intervals, id: \.self) { item in
                                Text(intervalTitle(item)).tag(item)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(intervalTitle(refreshInterval))
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(Color.purple)
                    }
                }
                .padding(.vertical, 2)
            }

            // MARK: - Refresh On
            NBSection(.localized("REFRESH ON")) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.pink.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "network")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.pink)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Network"))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("On any network connection"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)

                ForEach(networkOptions, id: \.self) { opt in
                    Button {
                        refreshNetworkOption = opt
                    } label: {
                        HStack {
                            ZStack {
                                Circle()
                                    .stroke(refreshNetworkOption == opt ? Color.pink : Color.secondary.opacity(0.4), lineWidth: 2)
                                    .frame(width: 20, height: 20)
                                if refreshNetworkOption == opt {
                                    Circle()
                                        .fill(Color.pink)
                                        .frame(width: 10, height: 10)
                                }
                            }
                            .padding(.trailing, 4)

                            Text(networkTitle(opt))
                                .font(.subheadline.weight(refreshNetworkOption == opt ? .semibold : .regular))
                                .foregroundStyle(refreshNetworkOption == opt ? Color.pink : .primary)

                            Spacer()

                            if refreshNetworkOption == opt {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.pink)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            // MARK: - Downloads
            NBSection(.localized("DOWNLOADS")) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.purple.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.purple)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Allow Downloads On"))
                            .font(.subheadline.weight(.semibold))
                        Text(.localized("On any network connection"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)

                ForEach(networkOptions, id: \.self) { opt in
                    Button {
                        downloadsNetworkOption = opt
                    } label: {
                        HStack {
                            ZStack {
                                Circle()
                                    .stroke(downloadsNetworkOption == opt ? Color.pink : Color.secondary.opacity(0.4), lineWidth: 2)
                                    .frame(width: 20, height: 20)
                                if downloadsNetworkOption == opt {
                                    Circle()
                                        .fill(Color.pink)
                                        .frame(width: 10, height: 10)
                                }
                            }
                            .padding(.trailing, 4)

                            Text(networkTitle(opt))
                                .font(.subheadline.weight(downloadsNetworkOption == opt ? .semibold : .regular))
                                .foregroundStyle(downloadsNetworkOption == opt ? Color.pink : .primary)

                            Spacer()

                            if downloadsNetworkOption == opt {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.pink)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(.localized("Controls which network types are used for app downloads"))
            }
        }
    }
}
