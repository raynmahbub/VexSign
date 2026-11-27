//
//  AutomationDomainEvents.swift
//  VexSign
//
//  Automation listens to the process-wide `NotificationCenter` that the app
//  already uses. It does not introduce a second event bus. The payload is a
//  small allow-list of values; no key, password, token or raw device UDID ever
//  goes through it.
//

import Foundation

extension Notification.Name {
    static let vexAutomationDomainEvent = Notification.Name("VexSign.automation.domainEvent")
    static let vexAutomationJobChanged = Notification.Name("VexSign.automation.jobChanged")
}

enum AutomationDomainEventKind: String, Sendable, CaseIterable {
    case certificateImported
    case certificateRemoved
    case certificateInspected
    case appUpdateFound
    case downloadCompleted
    case installCompleted
    case deviceChanged
    case backupCompleted
    case restoreCompleted
    case sourceRefreshed
    case automationFinished
}

struct AutomationDomainEvent: Equatable, Sendable {
    let kind: AutomationDomainEventKind
    /// Stable internal reference, never a UDID, key or secret. Empty when the
    /// event describes a summary rather than one object.
    let referenceID: String
    let summary: String
    /// Allow-listed values used to build a privacy-safe notification. Never
    /// include a secret, a raw UDID or an arbitrary payload here.
    let details: [String: String]
    let occurredAt: Date

    init(kind: AutomationDomainEventKind, referenceID: String = "", summary: String = "",
         details: [String: String] = [:], occurredAt: Date = Date()) {
        self.kind = kind
        self.referenceID = referenceID
        self.summary = summary
        self.details = details
        self.occurredAt = occurredAt
    }

    static func post(_ event: AutomationDomainEvent) {
        NotificationCenter.default.post(
            name: .vexAutomationDomainEvent,
            object: nil,
            userInfo: [
                "kind": event.kind.rawValue,
                "referenceID": event.referenceID,
                "summary": event.summary,
                "details": event.details,
                "occurredAt": event.occurredAt
            ]
        )
    }

    static func decode(_ notification: Notification) -> AutomationDomainEvent? {
        guard notification.name == .vexAutomationDomainEvent,
              let userInfo = notification.userInfo,
              let rawKind = userInfo["kind"] as? String,
              let kind = AutomationDomainEventKind(rawValue: rawKind) else { return nil }
        return AutomationDomainEvent(
            kind: kind,
            referenceID: userInfo["referenceID"] as? String ?? "",
            summary: userInfo["summary"] as? String ?? "",
            details: userInfo["details"] as? [String: String] ?? [:],
            occurredAt: userInfo["occurredAt"] as? Date ?? Date()
        )
    }
}
