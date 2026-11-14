import Foundation

/// Coordinates firmware catalog queries and validated HTTPS IPSW downloads into Documents/Firmware.
@MainActor
final class FirmwareDownloadUseCase {
    private let securityPolicy: SecurityPolicyValidating
    private let transferService: SecureTransferProviding
    private let firmwareDirectory: URL
    private let startKeepAlive: () -> () -> Void
    private let fileExists: (URL) -> Bool

    init(
        securityPolicy: SecurityPolicyValidating,
        transferService: SecureTransferProviding,
        firmwareDirectory: URL,
        fileExists: @escaping (URL) -> Bool,
        startKeepAlive: @escaping () -> () -> Void
    ) {
        self.securityPolicy = securityPolicy
        self.transferService = transferService
        self.firmwareDirectory = firmwareDirectory
        self.startKeepAlive = startKeepAlive
        self.fileExists = fileExists
    }

    func fetchDevices() async throws -> [FirmwareDeviceRecord] {
        try await transferService.fetchFirmwareDevices()
    }

    func fetchBuilds(for deviceIdentifier: String) async throws -> [FirmwareBuildRecord] {
        try await transferService.fetchFirmwareBuilds(deviceIdentifier: deviceIdentifier)
    }

    func currentHardwareModelIdentifier() -> String? {
        transferService.currentHardwareModelIdentifier()
    }

    func downloadedFileURL(for build: FirmwareBuildRecord) -> URL? {
        let candidate = firmwareDirectory.appendingPathComponent(build.filename)
        return fileExists(candidate) ? candidate : nil
    }

    func download(_ build: FirmwareBuildRecord) async throws -> URL {
        guard let source = build.downloadURL else {
            throw ArchitectureDomainError.invalidURL(build.filename)
        }
        try securityPolicy.validateFirmwareDownloadURL(source)

        let stopKeepAlive = startKeepAlive()
        defer { stopKeepAlive() }

        let destination = firmwareDirectory.appendingPathComponent(build.filename)
        return try await transferService.downloadValidatedFirmware(from: source, to: destination)
    }
}
