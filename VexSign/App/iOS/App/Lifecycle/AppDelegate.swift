import UIKit
import NimbleExtensions

class AppDelegate: NSObject, UIApplicationDelegate, DownloadManager.ErrorDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Create the store here, on the main thread, before anything else can
        // reach for it: the certificate importer starts from a utility queue a
        // few lines down, and whoever touches `Storage.shared` first is the
        // thread that creates the container.
        _ = Storage.shared

        // Anything still held from an "Undo" offer in an earlier session was never undone.
        RecoverableFileRemoval.sweep()

        BackgroundAndLifecyclePlatform.configureImagePipeline()
        BackgroundAndLifecyclePlatform.ensureDocumentsDirectories()
        StorageManager.purgeStaleTemporary()
        Storage.shared.recoverPendingAppDeletions()
        Storage.shared.recoverPendingCertificateDeletions()
        InstallCleanup.flushOnLaunch()
        _addDefaultCertificates()
        _registerBackgroundTasks()
        EcosystemMaintenance.register()
        EcosystemMaintenance.schedule()
        scheduleAutomationMaintenance()

        // Apple Watch companion: a no-op unless the user switched it on.
        CompanionBridge.shared.activateIfNeeded()

        // Idempotent, no-op after first run.
        VexSignAPI.migrateIfNeeded()

        // Attach the premium repository API key to every manifest fetch/decrypt request.
        RepositoryCatalogService.registerRepositoryKeyProvider()

        DownloadManager.shared.errorDelegate = self

        return true
    }

    // MARK: - DownloadManager.ErrorDelegate

    func showUIErrorMessage(title: String, message: String) {
        DispatchQueue.main.async {
            UIAlertController.showErrorWithCopy(
                title: .localized(title),
                message: message
            )
        }
    }

    /// A download that failed its integrity check needs an answer, not an acknowledgement —
    /// the file is either imported deliberately or deleted.
    func showUIErrorMessage(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void,
        dismissTitle: String,
        onDismiss: (() -> Void)?
    ) {
        DispatchQueue.main.async {
            UIAlertController.showAlertWithOptions(
                title: .localized(title),
                message: message,
                actions: [
                    (actionTitle, .default, action),
                    (dismissTitle, .cancel, onDismiss)
                ]
            )
        }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }

    private func _addDefaultCertificates() {
        CertificateAutoImporter.shared.importBundledCertificatesIfNeeded()
    }
}
