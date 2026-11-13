//
//  IPSWBrowserView.swift
//  VexSign
//
//  Browse and download Apple firmware through the ipsw.me catalog. Files land in
//  Documents/Firmware, so they show up in File Manager and in the Files app —
//  restoring is still Finder / Apple Configurator / a jailbreak tool's job.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct IPSWBrowserView: View {
    var inNavigationStack: Bool = true
    @Environment(\.appContainer) private var appContainer
    @State private var viewModel: FirmwareBrowserViewModel?

    init(inNavigationStack: Bool = true, viewModel: FirmwareBrowserViewModel? = nil) {
        self.inNavigationStack = inNavigationStack
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if let viewModel {
                IPSWBrowserContent(inNavigationStack: inNavigationStack, viewModel: viewModel)
            } else {
                ProgressView()
                    .onAppear {
                        let container = appContainer ?? AppContainer.live()
                        viewModel = container.makeFirmwareBrowserViewModel()
                    }
            }
        }
    }
}

private struct IPSWBrowserContent: View {
    let inNavigationStack: Bool
    @ObservedObject var viewModel: FirmwareBrowserViewModel

    var body: some View {
        if inNavigationStack {
            NBNavigationView(.localized("Firmware"), displayMode: .inline) {
                content
                    .toolbar {
                        NBToolbarButton(role: .close)
                    }
            }
            .task {
                await viewModel.loadDevicesIfNeeded()
            }
        } else {
            content
                .navigationTitle(.localized("Firmware"))
                .navigationBarTitleDisplayMode(.inline)
                .task {
                    await viewModel.loadDevicesIfNeeded()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            deviceSection
            firmwareSection
        }
        .searchable(text: $viewModel.deviceQuery, prompt: .localized("Search Devices"))
    }

    @ViewBuilder
    private var deviceSection: some View {
        NBSection(.localized("Device")) {
            if viewModel.isLoadingDevices {
                HStack {
                    ProgressView()
                        .padding(.trailing, 6)
                    Text(.localized("Loading devices…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(viewModel.filteredDevices) { device in
                deviceRow(device)
            }
        } footer: {
            Text(.localized("Firmware comes from Apple's CDN through the ipsw.me catalog. Files are stored in Documents → Firmware."))
        }
    }

    @ViewBuilder
    private var firmwareSection: some View {
        if let device = viewModel.selectedDevice {
            NBSection(String.localized("Firmware for %@", arguments: device.name)) {
                if viewModel.isLoadingFirmwares {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 6)
                        Text(.localized("Loading firmware…"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(viewModel.firmwares) { firmware in
                    firmwareRow(firmware)
                }
            }
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: FirmwareDeviceRecord) -> some View {
        Button {
            viewModel.selectDevice(device)
        } label: {
            HStack {
                Label(device.name, systemImage: "iphone")
                    .foregroundStyle(.primary)
                Spacer()
                Text(device.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if viewModel.selectedDevice?.identifier == device.identifier {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    @ViewBuilder
    private func firmwareRow(_ firmware: FirmwareBuildRecord) -> some View {
        let isDownloading = viewModel.downloadingIDs.contains(firmware.id)
        let isDownloaded = viewModel.isDownloaded(firmware)

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("iOS \(firmware.version)")
                        .font(.subheadline.weight(.semibold))
                    if firmware.isStillSigned {
                        Text(.localized("Signed"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text("\(firmware.buildID) • \(firmware.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloading {
                ProgressView()
            } else if isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    Task { await viewModel.download(firmware) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(firmware.downloadURL == nil)
            }
        }
    }
}
