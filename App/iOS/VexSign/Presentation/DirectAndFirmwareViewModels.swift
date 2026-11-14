import Foundation
import NimbleExtensions

// MARK: - Direct Install ViewModel

@MainActor
final class DirectInstallViewModel: ObservableObject {
    @Published var urlString: String = ""
    @Published var selectedMode: DirectInstallMode = .signAndInstall
    @Published private(set) var isProcessing = false
    @Published private(set) var statusMessage = ""

    private let useCase: DirectPackageInstallUseCase
    private let platform: PlatformSystemAdapting

    init(
        initialURL: String = "",
        initialMode: DirectInstallMode = .signAndInstall,
        useCase: DirectPackageInstallUseCase,
        platform: PlatformSystemAdapting
    ) {
        self.urlString = initialURL
        self.selectedMode = initialMode
        self.useCase = useCase
        self.platform = platform
    }

    func startInstall(onComplete: @escaping () -> Void) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetURL = URL(string: trimmed), targetURL.scheme != nil else {
            platform.notifyError(.localized("Please enter a valid URL."), sticky: false)
            return
        }

        isProcessing = true
        statusMessage = .localized("Downloading…")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }
            do {
                let result = try await self.useCase.execute(
                    urlString: trimmed,
                    mode: self.selectedMode,
                    onStatus: { [weak self] status in
                        self?.statusMessage = status
                    }
                )
                switch result {
                case .queuedForDownloadAndSign:
                    self.platform.notifySuccess(
                        .localized("Download queued for signing & installation"),
                        systemImage: "arrow.down.app"
                    )
                    onComplete()
                case .installedAsContainerGuest:
                    self.platform.notifySuccess(.localized("Guest import queued…"), systemImage: "shippingbox")
                    onComplete()
                case .installedDirectly:
                    self.platform.notifySuccess(.localized("Installing without signing…"), systemImage: "bolt.badge.checkmark")
                    onComplete()
                case .needsIssueConfirmation(let issues):
                    self.platform.presentYesNoAlert(
                        title: .localized("Install Anyway?"),
                        message: issues.joined(separator: "\n"),
                        confirmTitle: .localized("Install Anyway")
                    ) { [weak self] in
                        self?.confirmAnyway(onComplete: onComplete)
                    }
                }
            } catch {
                self.platform.notifyError(ErrorBoundary.userMessage(for: error), sticky: true)
            }
        }
    }

    private func confirmAnyway(onComplete: @escaping () -> Void) {
        do {
            _ = try useCase.confirmPendingInstall()
            platform.notifySuccess(.localized("Installing without signing…"), systemImage: "bolt.badge.checkmark")
            onComplete()
        } catch {
            platform.notifyError(ErrorBoundary.userMessage(for: error), sticky: true)
        }
    }
}

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
