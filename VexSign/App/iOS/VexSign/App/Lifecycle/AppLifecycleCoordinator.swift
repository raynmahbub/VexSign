import Foundation

/// App-shell orchestration only; each subsystem keeps its existing single owner.
/// There is no new scheduler, download manager, task center, or app registry.
@MainActor
enum AppLifecycleCoordinator {
    static func enterBackground() {
        EcosystemMaintenance.schedule()
        AppLockManager.shared.lockIfNeeded()
    }

    static func enterForeground() {
        Task { @MainActor in
            SourceCatalogStore.shared.resetLoadingState()
            LibraryStatusStore.shared.refreshKnown()
            InstallQueue.shared.reconcileOnForeground()
        }
        AppLockManager.shared.authenticateIfNeeded()
    }

    static func launch() async {
        await SelfUpdateManager.shared.checkOnLaunch()
        await EcosystemMaintenance.run()
        await CertificateExpiryMonitor.checkOnLaunch()
        StorageRules.warnIfOverLimit()
    }
}
