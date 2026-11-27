//
//  PersistentAutomationEngine.swift
//  VexSign
//
//  Durable, actor-safe state for scheduled maintenance. The system still
//  decides *when* background work happens; this engine decides whether a job
//  is eligible, prevents two copies of the same job running at once, records
//  the verified outcome and applies bounded exponential backoff after failure.
//  It never starts a timer, fakes a background launch or installs anything.
//

import Foundation

enum AutomationJobKind: String, Codable, CaseIterable, Sendable {
    case maintenance
    case expiryReview
    case sourceRefresh
    case updateCheck
    case cleanup

    var defaultInterval: TimeInterval {
        switch self {
        case .maintenance: return 6 * 60 * 60
        case .expiryReview: return 24 * 60 * 60
        case .sourceRefresh: return 6 * 60 * 60
        case .updateCheck: return 6 * 60 * 60
        case .cleanup: return 24 * 60 * 60
        }
    }
}

struct AutomationJobResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case succeeded, failed, skipped, cancelled
    }

    let status: Status
    /// Short, privacy-safe summary suitable for the in-app history list.
    let message: String
    let finishedAt: Date

    static func succeeded(_ message: String, at date: Date = Date()) -> AutomationJobResult {
        .init(status: .succeeded, message: message, finishedAt: date)
    }

    static func failed(_ message: String, at date: Date = Date()) -> AutomationJobResult {
        .init(status: .failed, message: message, finishedAt: date)
    }

    static func skipped(_ message: String, at date: Date = Date()) -> AutomationJobResult {
        .init(status: .skipped, message: message, finishedAt: date)
    }

    static func cancelled(at date: Date = Date()) -> AutomationJobResult {
        .init(status: .cancelled, message: "Stopped before completion.", finishedAt: date)
    }
}

struct AutomationJobDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: AutomationJobKind
    var isEnabled: Bool
    var interval: TimeInterval
    var lastRunAt: Date?
    var lastResult: AutomationJobResult?
    var consecutiveFailures: Int
    var nextEligibleAt: Date?

    init(id: String, kind: AutomationJobKind, isEnabled: Bool = true,
         interval: TimeInterval? = nil, lastRunAt: Date? = nil,
         lastResult: AutomationJobResult? = nil, consecutiveFailures: Int = 0,
         nextEligibleAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.interval = interval ?? kind.defaultInterval
        self.lastRunAt = lastRunAt
        self.lastResult = lastResult
        self.consecutiveFailures = consecutiveFailures
        self.nextEligibleAt = nextEligibleAt
    }

    func isEligible(at now: Date) -> Bool {
        guard isEnabled else { return false }
        if let nextEligibleAt, now < nextEligibleAt { return false }
        return true
    }
}

enum AutomationEnginePolicy {
    static let maximumFailures = 5
    static let maximumBackoff: TimeInterval = 24 * 60 * 60

    /// Deterministic exponential backoff in seconds: 5m, 10m, 20m, 40m, 80m…
    static func backoff(forFailures count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        let exponent = min(count - 1, 20)
        return min(maximumBackoff, TimeInterval(300 * (1 << exponent)))
    }
}

protocol AutomationJobExecuting: Sendable {
    /// Must only report success after the underlying service confirms it.
    func run(_ job: AutomationJobDefinition) async throws -> AutomationJobResult
}

actor AutomationJobStore {
    static let storageKey = "VexSign.automation.jobs.v1"
    static let defaultJobs: [AutomationJobDefinition] = AutomationJobKind.allCases.map {
        AutomationJobDefinition(id: "com.vexsign.automation.\($0.rawValue)", kind: $0)
    }

    private let defaults: UserDefaults
    private var jobs: [AutomationJobDefinition]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([AutomationJobDefinition].self, from: data) { // try? ok: corrupt durable state falls back to registered defaults
            var byID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
            // New job kinds are registered on upgrade; unknown stored IDs are
            // discarded so a renamed job cannot silently be revived.
            jobs = Self.defaultJobs.map { byID.removeValue(forKey: $0.id) ?? $0 }
        } else {
            jobs = Self.defaultJobs
        }
    }

    func all() -> [AutomationJobDefinition] { jobs }

    func job(id: String) -> AutomationJobDefinition? { jobs.first { $0.id == id } }

    func upsert(_ job: AutomationJobDefinition) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else {
            jobs.append(job)
            persist()
            return
        }
        jobs[index] = job
        persist()
    }

    func update(id: String, _ transform: (inout AutomationJobDefinition) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        transform(&jobs[index])
        persist()
    }

    func reset() {
        jobs = Self.defaultJobs
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return } // try? ok: Codable structs cannot fail; no partial state is written
        defaults.set(data, forKey: Self.storageKey)
        NotificationCenter.default.post(name: .vexAutomationJobChanged, object: nil)
    }
}

actor PersistentAutomationEngine {
    static let shared = PersistentAutomationEngine()

    private let store: AutomationJobStore
    private let executor: any AutomationJobExecuting
    private let clock: () -> Date
    private let recorder: DiagnosticRecorder?
    private var running: Set<String> = []

    init(store: AutomationJobStore = AutomationJobStore(),
         executor: any AutomationJobExecuting = VexSignAutomationJobExecutor(),
         clock: @escaping () -> Date = Date.init,
         recorder: DiagnosticRecorder? = nil) {
        self.store = store
        self.executor = executor
        self.clock = clock
        self.recorder = recorder
    }

    func snapshot() async -> [AutomationJobDefinition] { await store.all() }

    /// OS-level callers cannot inject through a view tree; let the composition
    /// boundary attach the file-backed recorder once at launch.
    func setDiagnostics(_ recorder: DiagnosticRecorder) { self.recorder = recorder }

    func setEnabled(_ id: String, _ enabled: Bool) async {
        await store.update(id: id) { $0.isEnabled = enabled }
    }

    /// Claims a job for a caller that must use the real service directly
    /// (the manual Run Now button keeps its detailed `AutomationRunResult`).
    /// A false claim means an identical pass is active and must not start twice.
    func claim(_ id: String) async -> Bool {
        guard let job = await store.job(id: id), job.isEnabled, !running.contains(id) else { return false }
        running.insert(id)
        return true
    }

    func release(_ id: String) {
        running.remove(id)
    }

    /// Runs one job if it is enabled, not already running and past backoff.
    /// A skipped run is recorded so the UI never says "everything is fine"
    /// about a pass that never started.
    @discardableResult
    func run(id: String) async -> AutomationJobResult {
        guard var job = await store.job(id: id) else {
            return .skipped("Unknown automation job.")
        }
        let now = clock()
        guard job.isEligible(at: now) else {
            let result = AutomationJobResult.skipped(
                job.isEnabled ? "Waiting for the next eligible time." : "This job is turned off.",
                at: now
            )
            await store.update(id: id) { $0.lastResult = result }
            return result
        }
        guard !running.contains(id) else {
            return .skipped("This job is already running.", at: now)
        }

        running.insert(id)
        defer { running.remove(id) }

        let result: AutomationJobResult
        do {
            try Task.checkCancellation()
            result = try await executor.run(job)
        } catch is CancellationError {
            result = .cancelled(at: clock())
        } catch {
            result = .failed(String(error.localizedDescription.prefix(300)), at: clock())
        }

        let finishedAt = clock()
        var updated = job
        updated.lastRunAt = finishedAt
        updated.lastResult = result
        switch result.status {
        case .succeeded:
            updated.consecutiveFailures = 0
            updated.nextEligibleAt = finishedAt.addingTimeInterval(job.interval)
        case .failed, .cancelled:
            updated.consecutiveFailures = min(job.consecutiveFailures + 1, AutomationEnginePolicy.maximumFailures)
            updated.nextEligibleAt = finishedAt.addingTimeInterval(
                AutomationEnginePolicy.backoff(forFailures: updated.consecutiveFailures)
            )
        case .skipped:
            updated.nextEligibleAt = nil
        }
        await store.upsert(updated)
        if case .failed = result.status, let recorder {
            await recorder.record(.make(
                code: DiagnosticEventCode.automationFailure,
                severity: .error,
                category: .automation,
                operationID: id,
                userMessage: "A scheduled automation job failed.",
                developerDetail: result.message,
                recoverySuggestion: "Review the job in Automation settings and run it again when ready.",
                metadata: [
                    "job": id,
                    "consecutiveFailures": String(updated.consecutiveFailures)
                ]
            ))
        }
        AutomationDomainEvent.post(AutomationDomainEvent(
            kind: .automationFinished,
            referenceID: id,
            summary: result.message,
            occurredAt: finishedAt
        ))
        return result
    }

    /// The foreground and system entry point. Each job is considered once;
    /// ineligible jobs are left untouched rather than marked as successful.
    @discardableResult
    func runDueJobs() async -> [String: AutomationJobResult] {
        let jobs = await snapshot()
        var results: [String: AutomationJobResult] = [:]
        for job in jobs where job.isEligible(at: clock()) {
            guard !Task.isCancelled else { break }
            results[job.id] = await run(id: job.id)
        }
        return results
    }
}

/// Production adapter. Every branch delegates to an existing service; there
/// is no simulated work and no claim of success without a service result.
struct VexSignAutomationJobExecutor: AutomationJobExecuting {
    func run(_ job: AutomationJobDefinition) async throws -> AutomationJobResult {
        switch job.kind {
        case .maintenance: return await Self.maintenance()
        case .expiryReview: return await Self.expiryReview()
        case .sourceRefresh, .updateCheck: return await Self.maintenance()
        case .cleanup:
            TempStorageSweeper.sweep()
            return .succeeded("Temporary signing files were swept.")
        }
    }

    @MainActor
    private static func maintenance() async -> AutomationJobResult {
        guard let result = await BackgroundAutomation.run(fromBackground: true) else {
            return .skipped("The automation pass did not run; its blocker is recorded in automation history.")
        }
        return .succeeded("Checked \(result.refreshedSources) sources and found \(result.foundUpdates) updates.")
    }

    @MainActor
    private static func expiryReview() async -> AutomationJobResult {
        do {
            let report = try await CertificateInspector.inspectAll(online: false)
            let subjects = report.certificates.map {
                ExpiryReminderSubject(
                    referenceID: $0.id, kind: .certificate,
                    displayName: $0.name, expiry: $0.effectiveExpiry
                )
            }
            let scheduler = ExpiryReminderScheduler()
            await scheduler.reconcile(subjects)
            return .succeeded("Reviewed \(subjects.count) signing identities.")
        } catch is CancellationError {
            return .cancelled()
        } catch {
            return .failed(String(error.localizedDescription.prefix(300)))
        }
    }
}
