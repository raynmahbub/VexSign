import Foundation
import Combine
import NimbleExtensions

// MARK: - Firmware Browser ViewModel

@MainActor
final class FirmwareBrowserViewModel: ObservableObject {
    @Published private(set) var devices: [FirmwareDeviceRecord] = []
    @Published private(set) var firmwares: [FirmwareBuildRecord] = []
    @Published private(set) var selectedDevice: FirmwareDeviceRecord?
    @Published private(set) var isLoadingDevices = false
    @Published private(set) var isLoadingFirmwares = false
    @Published private(set) var downloadingIDs: Set<String> = []
    @Published var deviceQuery = ""
    @Published var errorMessage: String?

    private let useCase: FirmwareDownloadUseCase
    private let platform: PlatformSystemAdapting

    init(useCase: FirmwareDownloadUseCase, platform: PlatformSystemAdapting) {
        self.useCase = useCase
        self.platform = platform
    }

    var filteredDevices: [FirmwareDeviceRecord] {
        let query = deviceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return devices }
        return devices.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.identifier.localizedCaseInsensitiveContains(query)
        }
    }

    func loadDevicesIfNeeded() async {
        guard devices.isEmpty, !isLoadingDevices else { return }
        isLoadingDevices = true
        defer { isLoadingDevices = false }

        do {
            devices = try await useCase.fetchDevices()
            if let current = useCase.currentHardwareModelIdentifier(),
               let match = devices.first(where: { $0.identifier == current }) {
                selectDevice(match)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectDevice(_ device: FirmwareDeviceRecord) {
        selectedDevice = device
        firmwares = []
        Task { @MainActor in
            await loadFirmwares(for: device)
        }
    }

    func isDownloaded(_ build: FirmwareBuildRecord) -> Bool {
        useCase.downloadedFileURL(for: build) != nil
    }

    func download(_ build: FirmwareBuildRecord) async {
        guard !downloadingIDs.contains(build.id) else { return }
        downloadingIDs.insert(build.id)
        defer { downloadingIDs.remove(build.id) }

        do {
            _ = try await useCase.download(build)
            platform.notifySuccess(
                String.localized("Downloaded %@", arguments: build.filename),
                systemImage: "arrow.down.circle.fill"
            )
        } catch {
            platform.notifyError(ErrorBoundary.userMessage(for: error), sticky: true)
        }
    }

    private func loadFirmwares(for device: FirmwareDeviceRecord) async {
        guard !isLoadingFirmwares else { return }
        isLoadingFirmwares = true
        defer { isLoadingFirmwares = false }

        do {
            firmwares = try await useCase.fetchBuilds(for: device.identifier)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
