import Foundation
import NimbleExtensions
import os

/// Concrete infrastructure adapter for validated package & firmware transfers.
final class NetworkTransferAdapter: SecureTransferProviding {
    private let securityPolicy: SecurityPolicyValidating
    // Only directories created by this adapter may be released by a caller.
    private let ownedPackages = OSAllocatedUnfairLock(initialState: [URL: URL]())

    init(securityPolicy: SecurityPolicyValidating) {
        self.securityPolicy = securityPolicy
    }

    func downloadValidatedPackage(
        from url: URL,
        workLabel: String,
        maximumBytes: Int64
    ) async throws -> URL {
        try securityPolicy.validatePackageDownloadURL(url)
        let tempURL = try await TransferSecuritySession.download(
            url: url,
            maximumBytes: maximumBytes,
            requestTimeout: 60,
            applyAuthHeaders: true
        )

        // The system temporary file and an incompletely staged directory remain
        // ours on every error, including failure to create the destination.
        defer {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                do { try FileManager.default.removeItem(at: tempURL) }
                catch { SubsystemDiagnosticsLog.warn("Could not clean temporary package: \(error.localizedDescription)", subsystem: .network) }
            }
        }
        let directory = try DownloadStagingPath.createTemporaryDirectory(label: workLabel)
        var handedOff = false
        defer {
            if !handedOff {
                do { try FileManager.default.removeItem(at: directory) }
                catch { SubsystemDiagnosticsLog.warn("Could not clean failed package staging: \(error.localizedDescription)", subsystem: .network) }
            }
        }
        let suggested = url.lastPathComponent.isEmpty ? "package.ipa" : url.lastPathComponent
        let destination = directory.appendingPathComponent(DownloadStagingPath.safeFilename(suggested))
        try FileManager.default.moveItem(at: tempURL, to: destination)
        try Task.checkCancellation()
        ownedPackages.withLock { $0[destination.standardizedFileURL] = directory }
        handedOff = true
        return destination
    }

    func releaseValidatedPackage(_ url: URL) {
        let directory = ownedPackages.withLock { $0.removeValue(forKey: url.standardizedFileURL) }
        guard let directory else { return }
        do {
            _ = try CleanupRemovalPolicy.remove(directory, beneath: FileManager.default.temporaryDirectory)
        } catch {
            SubsystemDiagnosticsLog.warn("Could not clean owned package staging: \(error.localizedDescription)", subsystem: .network)
        }
    }

    func downloadValidatedFirmware(from url: URL, to destination: URL) async throws -> URL {
        try securityPolicy.validateFirmwareDownloadURL(url)
        let tempURL = try await TransferSecuritySession.download(
            url: url,
            maximumBytes: nil,
            requestTimeout: 120,
            applyAuthHeaders: false
        )

        let fm = FileManager.default
        do {
            try fm.createDirectoryIfNeeded(at: destination.deletingLastPathComponent())
            try fm.removeFileIfNeeded(at: destination)
            try fm.moveItem(at: tempURL, to: destination)
            return destination
        } catch {
            do {
                try fm.removeItem(at: tempURL)
            } catch {
                SubsystemDiagnosticsLog.warn(
                    "Could not clean temporary firmware file: \(error.localizedDescription)",
                    subsystem: .network
                )
            }
            throw error
        }
    }

    func fetchFirmwareDevices() async throws -> [FirmwareDeviceRecord] {
        let devices = try await IPSWBrowser.fetchDevices()
        return devices.map {
            FirmwareDeviceRecord(
                name: $0.name,
                identifier: $0.identifier,
                boardConfig: $0.boardconfig,
                platform: $0.platform
            )
        }
    }

    func fetchFirmwareBuilds(deviceIdentifier: String) async throws -> [FirmwareBuildRecord] {
        let builds = try await IPSWBrowser.fetchFirmwares(for: deviceIdentifier)
        return builds.map {
            FirmwareBuildRecord(
                identifier: $0.identifier,
                version: $0.version,
                buildID: $0.buildid,
                fileSize: $0.filesize,
                downloadURL: $0.downloadURL,
                isStillSigned: $0.isStillSigned,
                formattedSize: $0.formattedSize,
                filename: $0.filename
            )
        }
    }

    func currentHardwareModelIdentifier() -> String? {
        IPSWBrowser.currentDeviceIdentifier()
    }
}
