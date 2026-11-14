import Foundation
import NimbleExtensions

/// Coordinates firmware catalog queries and validated HTTPS IPSW downloads into Documents/Firmware.
@MainActor
final class FirmwareDownloadUseCase {
    private let securityPolicy: SecurityPolicyValidating
    private let transferService: SecureTransferProviding
    private let firmwareDirectory: URL
    private let startKeepAlive: () -> () -> Void

    init(
        securityPolicy: SecurityPolicyValidating,
        transferService: SecureTransferProviding,
        firmwareDirectory: URL = FileManager.default.firmware,
        startKeepAlive: @escaping () -> () -> Void
    ) {
        self.securityPolicy = securityPolicy
        self.transferService = transferService
        self.firmwareDirectory = firmwareDirectory
        self.startKeepAlive = startKeepAlive
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
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
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
