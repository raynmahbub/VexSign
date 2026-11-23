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
        do { try await PairingBridge.recoverLocalStorage() }
        catch {
            // Do not log a credential path or raw file-provider/native error.
            // Bootstrap retries after unlock; it never falls back to Documents.
            FileLogger.error("Pairing storage recovery deferred; unlock and review device bootstrap.", category: "bootstrap")
        }
        // Prime the vault before anything can publish a widget payload or start a
        // backup: `StrictHidingSnapshot` only knows what the vault has published, and
        // an unprimed mirror would report hidden apps as visible.
        _ = AppLockManager.shared
        await SelfUpdateManager.shared.checkOnLaunch()
        await EcosystemMaintenance.run()
        await CertificateExpiryMonitor.checkOnLaunch()
        await StorageRules.warnIfOverLimit()
    }
}
