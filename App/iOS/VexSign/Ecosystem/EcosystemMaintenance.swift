import BackgroundTasks
import UserNotifications
import Foundation

@MainActor
enum EcosystemMaintenance {
    static let identifier = "com.vexsign.ecosystem.refresh"
    static func register() {
        guard EmbeddedContainerRuntime.supportsScheduledGuestTasks else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task { @MainActor in
                schedule()
                await run()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }
    static func schedule() {
        guard EmbeddedContainerRuntime.supportsScheduledGuestTasks else { return }
        guard UserDefaults.standard.bool(forKey: "VexSign.ecosystem.certificateMonitoring") || UserDefaults.standard.bool(forKey: "VexSign.ecosystem.repositoryAutoRefresh") else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier); return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch { FileLogger.log("Ecosystem refresh could not be scheduled: \(error.localizedDescription)", category: "update") }
    }
    static func run() async {
        guard !GameMode.isEnabled else { return }
        // Housekeeping: drop leftover signing/backup temp working directories
        // from interrupted runs so app bundles don't linger in temp storage.
        TempStorageSweeper.sweep()
        let defaults = UserDefaults.standard
        let lastRefresh = defaults.object(forKey: "VexSign.ecosystem.lastRepositoryRefresh") as? Date ?? .distantPast
        if defaults.bool(forKey: "VexSign.ecosystem.repositoryAutoRefresh"), Date().timeIntervalSince(lastRefresh) >= RepositorySyncEngine.refreshInterval {
            let sources = Storage.shared.getSources()
            await SourcesViewModel.shared.fetchSources(sources)
            if !Task.isCancelled, SourcesViewModel.shared.sources.count == sources.count {
                defaults.set(Date(), forKey: "VexSign.ecosystem.lastRepositoryRefresh")
            }
        }
        guard !Task.isCancelled, defaults.bool(forKey: "VexSign.ecosystem.certificateMonitoring") else { return }
        let lastCheck = UserDefaults.standard.object(forKey: "VexSign.ecosystem.lastCertificateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= 86_400 else { return }
        let model = CertificateDashboardViewModel()
        await model.refresh(online: true)
        guard !Task.isCancelled else { return }
        if model.errors.isEmpty { UserDefaults.standard.set(Date(), forKey: "VexSign.ecosystem.lastCertificateCheck") }
        for cert in model.certificates where cert.daysRemaining <= 14 || cert.revocation == .revoked {
            let content = UNMutableNotificationContent()
            content.title = "Certificate Health Alert"
            content.body = cert.revocation == .revoked ? "\(cert.name) has been revoked." : "\(cert.name): \(cert.daysRemaining) days until profile expiry."
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "health.\(cert.id)", content: content, trigger: nil))
        }
    }
}
