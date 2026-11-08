import Foundation

/// A private workspace whose lifetime follows every consumer, including HTTP
/// response bodies. Never owns an original library bundle or an exported IPA.
final class InstallationArchive: Sendable {
    let directory: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        directory = temporaryRoot.appendingPathComponent("VexSignInstall_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        do { try FileManager.default.removeItem(at: directory) }
        catch { FileLogger.log("Could not clean installation workspace: \(error)", category: "install") }
    }
}

struct PreparedInstallationPackage: Sendable {
    let url: URL
    let exported: URL?
    let archive: InstallationArchive
}

/// Parallel preparation is intentionally limited to OTA-to-OTA queue entries.
enum InstallPreparationPolicy {
    static func allows(installationMethod: Int, currentIsExport: Bool, nextIsExport: Bool) -> Bool {
        installationMethod == 0 && !currentIsExport && !nextIsExport
    }
}
