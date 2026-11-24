import Foundation
import Nuke
import NimbleExtensions

/// Encapsulates launch-time filesystem directory initialization and image cache pipeline setup
/// so `AppDelegate` stays a slim lifecycle adapter.
enum BackgroundAndLifecyclePlatform {
    static func configureImagePipeline() {
        DataLoader.sharedUrlCache.diskCapacity = 0

        let pipeline = ImagePipeline {
            let dataLoader: DataLoader = {
                let config = URLSessionConfiguration.default
                config.urlCache = nil
                return DataLoader(configuration: config)
            }()
            let dataCache: DataCache?
            do {
                dataCache = try DataCache(name: "com.vexsign.datacache")
            } catch {
                SubsystemDiagnosticsLog.warn(
                    "Could not create disk DataCache: \(error.localizedDescription)",
                    subsystem: .storage
                )
                dataCache = nil
            }
            let imageCache = Nuke.ImageCache()
            dataCache?.sizeLimit = 500 * 1024 * 1024
            imageCache.costLimit = 100 * 1024 * 1024
            $0.dataCache = dataCache
            $0.imageCache = imageCache
            $0.dataLoader = dataLoader
            $0.dataCachePolicy = .automatic
            $0.isStoringPreviewsInMemoryCache = false
        }

        ImagePipeline.shared = pipeline
    }

    static func ensureDocumentsDirectories(fileManager: FileManager = .default) {
        let directories: [URL] = [
            fileManager.archives,
            fileManager.certificates,
            fileManager.signed,
            fileManager.unsigned,
            // Created here so the backup exclusion below always has something to
            // mark: a folder this app never created cannot be flagged.
            fileManager.firmware,
            fileManager.webManagerInbox,
            fileManager.logs
        ]

        for url in directories {
            do {
                try fileManager.createDirectoryIfNeeded(at: url)
            } catch {
                SubsystemDiagnosticsLog.warn(
                    "Could not create directory \(url.lastPathComponent): \(error.localizedDescription)",
                    subsystem: .storage
                )
            }
        }

        // Derived folders are not user content and must not ride in a device backup:
        // an .ipsw is re-downloadable and multi-gigabyte, the Web Manager inbox is a
        // hop for files the user is already sending elsewhere, and the log folder is
        // diagnostics. The library folders stay backed up on purpose - that is the
        // user's own content, and the password-protected Backup feature is the
        // supported way to move it between devices.
        for url in [fileManager.firmware, fileManager.webManagerInbox, fileManager.logs] {
            fileManager.excludeFromBackup(url)
        }
    }
}
