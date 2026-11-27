//
//  AutomationEventCoordinator.swift
//  VexSign
//
//  Turns confirmed domain events into privacy-safe notifications and expiry
//  reminder updates. This is a subscriber to the process-wide NotificationCenter,
//  not a new event bus, and it never invents an outcome: callers post an event
//  only after their own service has verified the result.
//

import Foundation
import NimbleExtensions

enum AutomationEventDetailKey: String, Sendable {
    case referenceID
    case expiry
    case displayName
    case version
    case build
    case bundleID
    case outcome
}

@MainActor
final class AutomationEventCoordinator: ObservableObject {
    static let shared = AutomationEventCoordinator()

    @Published private(set) var handledEvents = 0

    private let service: VexSignNotificationService
    private var observer: NSObjectProtocol?
    private var processed: Set<String> = []
    private let clock: () -> Date

    init(service: VexSignNotificationService = .shared, clock: @escaping () -> Date = Date.init) {
        self.service = service
        self.clock = clock
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .vexAutomationDomainEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = AutomationDomainEvent.decode(notification) else { return }
            Task { @MainActor in await self?.handle(event) }
        }
    }

    /// Idempotent for one event per day. Repeated confirmations from a retry
    /// cannot deliver two banners for the same completed action.
    func handle(_ event: AutomationDomainEvent) async {
        let signature = "\(event.kind.rawValue)|\(event.referenceID)|\(dayStamp(at: event.occurredAt))"
        guard !processed.contains(signature) else { return }
        processed.insert(signature)
        if processed.count > 500 { processed = Set(processed.suffix(250)) }
        handledEvents += 1

        switch event.kind {
        case .certificateImported, .certificateInspected:
            guard let subject = Self.expirySubject(from: event) else { return }
            let scheduler = ExpiryReminderScheduler(service: service)
            await scheduler.reconcile([subject])
        case .certificateRemoved:
            guard let subject = Self.expirySubject(from: event) else { return }
            ExpiryReminderScheduler(service: service).cancel(subject: subject)
            service.cancel(prefix: "com.vexsign.expiry.certificate." +
                VexSignNotificationService.digest(subject.referenceID))
        case .appUpdateFound, .downloadCompleted, .installCompleted,
             .deviceChanged, .backupCompleted, .restoreCompleted, .sourceRefreshed:
            guard let note = Self.notification(for: event) else { return }
            await service.post(note, dedupeContentKey: note.identifier)
        case .automationFinished:
            // The durable job record is the report; a second banner would be noise.
            break
        }
    }

    private func dayStamp(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Pure mapping used by automated tests. Returning nil means the event is
    /// not something the user needs to be interrupted about.
    nonisolated static func notification(for event: AutomationDomainEvent) -> VexSignNotification? {
        let details = event.details
        func value(_ key: AutomationEventDetailKey) -> String {
            details[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let reference = value(.referenceID)
        let digest = VexSignNotificationService.digest(reference)

        switch event.kind {
        case .appUpdateFound:
            let version = value(.version)
            guard !version.isEmpty else { return nil }
            return VexSignNotification(
                identifier: "com.vexsign.update.\(digest).\(VexSignNotificationService.digest(version))",
                topic: .appUpdates,
                title: .localized("App update available"),
                body: event.summary.isEmpty
                    ? .localized("A newer version of an installed app is available. Open VexSign to review it.")
                    : event.summary,
                category: .update,
                details: [
                    NotificationPayloadKey.route.rawValue: "updates",
                    NotificationPayloadKey.version.rawValue: version,
                    NotificationPayloadKey.bundleID.rawValue: value(.bundleID)
                ],
                isTimeSensitive: false
            )
        case .downloadCompleted, .installCompleted:
            let outcome = value(.outcome)
            guard !outcome.isEmpty else { return nil }
            return VexSignNotification(
                identifier: "com.vexsign.task.\(event.kind.rawValue).\(digest)",
                topic: .downloads,
                title: event.kind == .installCompleted
                    ? .localized("Installation update")
                    : .localized("Download update"),
                body: event.summary,
                category: .task,
                details: [
                    NotificationPayloadKey.route.rawValue: "tasks",
                    NotificationPayloadKey.outcome.rawValue: outcome
                ]
            )
        case .backupCompleted:
            return VexSignNotification(
                identifier: "com.vexsign.backup.\(digest)",
                topic: .backups,
                title: .localized("Backup update"),
                body: event.summary,
                category: .task,
                details: [NotificationPayloadKey.route.rawValue: "tasks",
                          NotificationPayloadKey.outcome.rawValue: value(.outcome)]
            )
        case .restoreCompleted:
            return VexSignNotification(
                identifier: "com.vexsign.restore.\(digest)",
                topic: .backups,
                title: .localized("Restore update"),
                body: event.summary,
                category: .task,
                details: [NotificationPayloadKey.route.rawValue: "tasks",
                          NotificationPayloadKey.outcome.rawValue: value(.outcome)]
            )
        case .deviceChanged:
            return VexSignNotification(
                identifier: "com.vexsign.device.\(digest)",
                topic: .devices,
                title: .localized("Device update"),
                body: event.summary,
                category: .task,
                details: [NotificationPayloadKey.route.rawValue: "tasks"]
            )
        case .sourceRefreshed:
            return VexSignNotification(
                identifier: "com.vexsign.source.\(digest)",
                topic: .sources,
                title: .localized("Source update"),
                body: event.summary,
                category: .source,
                details: [NotificationPayloadKey.route.rawValue: "sources"]
            )
        case .certificateImported, .certificateRemoved, .certificateInspected, .automationFinished:
            return nil
        }
    }

    nonisolated static func expirySubject(from event: AutomationDomainEvent) -> ExpiryReminderSubject? {
        let name = event.details[AutomationEventDetailKey.displayName.rawValue] ?? .localized("Certificate")
        let reference = event.details[AutomationEventDetailKey.referenceID.rawValue] ?? event.referenceID
        guard !reference.isEmpty else { return nil }
        var expiry: Date?
        if let raw = event.details[AutomationEventDetailKey.expiry.rawValue] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiry = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        }
        return ExpiryReminderSubject(
            referenceID: reference,
            kind: .certificate,
            displayName: name,
            expiry: expiry
        )
    }
}
