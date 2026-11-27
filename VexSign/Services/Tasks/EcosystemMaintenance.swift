import BackgroundTasks
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
            await SourceCatalogStore.shared.fetchSources(sources)
            if !Task.isCancelled, SourceCatalogStore.shared.sources.count == sources.count {
                defaults.set(Date(), forKey: "VexSign.ecosystem.lastRepositoryRefresh")
                AutomationDomainEvent.post(AutomationDomainEvent(
                    kind: .sourceRefreshed,
                    summary: "Refreshed \(sources.count) source(s)."
                ))
            }
        }
        guard !Task.isCancelled, defaults.bool(forKey: "VexSign.ecosystem.certificateMonitoring") else { return }
        let lastCheck = UserDefaults.standard.object(forKey: "VexSign.ecosystem.lastCertificateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= 86_400 else { return }
        let report: CertificateHealthReport
        do {
            report = try await CertificateInspector.inspectAll(online: true)
        } catch is CancellationError {
            return
        } catch {
            FileLogger.error("Scheduled certificate inspection could not complete: \(error.localizedDescription)", category: "certificates")
            return
        }
        guard !Task.isCancelled else { return }
        if report.errors.isEmpty { UserDefaults.standard.set(Date(), forKey: "VexSign.ecosystem.lastCertificateCheck") }
        // One scheduler owns expiry reminders. Inspected metadata supplies both
        // dates; a missing date stays unknown and produces no reminder.
        var subjects: [ExpiryReminderSubject] = []
        for cert in report.certificates {
            subjects.append(ExpiryReminderSubject(
                referenceID: cert.id + "-profile",
                kind: .profile,
                displayName: cert.name,
                expiry: cert.expires
            ))
            if let certificateExpiry = cert.certificateExpires {
                subjects.append(ExpiryReminderSubject(
                    referenceID: cert.id + "-certificate",
                    kind: .certificate,
                    displayName: cert.name,
                    expiry: certificateExpiry
                ))
            }
        }
        await ExpiryReminderScheduler().reconcile(subjects)
        AutomationDomainEvent.post(AutomationDomainEvent(
            kind: .certificateInspected,
            summary: "Reviewed \(report.certificates.count) signing identities."
        ))
    }
}
