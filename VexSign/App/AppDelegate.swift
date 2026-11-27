import UIKit
import NimbleExtensions

class AppDelegate: NSObject, UIApplicationDelegate, DownloadManager.ErrorDelegate {
    /// Retained for the process lifetime; MetricKit owns the callback registration.
    private let metricKitDiagnostics = MetricKitDiagnosticsService()

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

        // Notification categories, preferences and routing are configured before
        // any subsystem can post. The window below is deliberately detached:
        // it must not block the launch path or request permission implicitly.
        Task { @MainActor in
            VexSignNotificationService.shared.configure()
            AutomationEventCoordinator.shared.start()
            await ExpiryReminderScheduler().reconcile(ExpiryReminderSource.subjects())
        }

        // Apple Watch companion: a no-op unless the user switched it on.
        CompanionBridge.shared.activateIfNeeded()

        // Idempotent, no-op after first run.
        VexSignAPI.migrateIfNeeded()

        // Attach the premium repository API key to every manifest fetch/decrypt request.
        RepositoryCatalogService.registerRepositoryKeyProvider()

        DownloadManager.shared.errorDelegate = self

        // System diagnostics are opt-in-free and local: no crash SDK, no upload.
        // Delivery stays under iOS control and never happens in a simulator.
        metricKitDiagnostics.start()
        Task {
            await PersistentAutomationEngine.shared.setDiagnostics(.fileRecorder)
            await DiagnosticRecorder.fileRecorder.record(.make(
                code: DiagnosticEventCode.appLaunched,
                severity: .info,
                category: .app,
                userMessage: "VexSign finished launching.",
                developerDetail: "Launch recorded after store recovery and background registration.",
                metadata: [
                    "appVersion": VexSignBuildInfo.version,
                    "appBuild": VexSignBuildInfo.build,
                    "buildChannel": VexSignBuildInfo.configuration,
                    "sourceCommit": VexSignBuildInfo.commit,
                    "scheduledTasksAvailable": EmbeddedContainerRuntime.supportsScheduledGuestTasks ? "yes" : "no"
                ]
            ))
        }

        return true
    }

    // MARK: - DownloadManager.ErrorDelegate

    /// `title` is already localized by the caller: it is a sentence, not a catalogue key.
    /// Re-wrapping it here looked the translation up a second time, so a title that happened to
    /// match another key could show that key's string instead.
    func showUIErrorMessage(title: String, message: String) {
        DispatchQueue.main.async {
            UIAlertController.showErrorWithCopy(
                title: title,
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
                title: title,
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
