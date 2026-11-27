//
//  ExpiryReminderScheduler.swift
//  VexSign
//
//  Calendar-day expiry reminders for signing certificates and provisioning
//  profiles. Dates come from inspected metadata, never from a guess: when a
//  date is absent the status is `unknown` and no reminder is scheduled.
//
//  A milestone is scheduled once at the exact calendar date that is N days
//  before expiry. If VexSign first opens after that date, only the single most
//  urgent missed milestone is posted immediately — opening the app late must
//  not produce a stack of overdue warnings.
//

import Foundation
import UserNotifications
import NimbleExtensions

enum ExpiryMilestone: Int, Codable, CaseIterable, Hashable, Sendable {
    case days30 = 30
    case days14 = 14
    case days7 = 7
    case days1 = 1
    case expired = 0

    var days: Int { rawValue }

    var title: String {
        switch self {
        case .days30: return .localized("Certificate or profile expires in 30 days")
        case .days14: return .localized("Certificate or profile expires in 14 days")
        case .days7: return .localized("Certificate or profile expires in 7 days")
        case .days1: return .localized("Certificate or profile expires tomorrow")
        case .expired: return .localized("Certificate or profile expired")
        }
    }

    func body(name: String) -> String {
        switch self {
        case .expired:
            return .localized("“%@” is past its expiration date. Renew it before relying on it for signing.", arguments: name)
        case .days1:
            return .localized("“%@” expires tomorrow. Renew it to keep signing apps.", arguments: name)
        default:
            return .localized("“%@” is approaching its expiration date. Review it before it stops working.", arguments: name)
        }
    }
}

enum ExpiryReferenceKind: String, Sendable {
    case certificate
    case profile

    var topic: NotificationTopic {
        switch self {
        case .certificate: return .certificateExpiry
        case .profile: return .profileExpiry
        }
    }
}

/// Metadata only: a stable internal identifier, a display name the user chose,
/// and the date read from the profile or certificate. No key material travels
/// with this value.
struct ExpiryReminderSubject: Equatable, Sendable {
    let referenceID: String
    let kind: ExpiryReferenceKind
    let displayName: String
    let expiry: Date?
}

enum ExpiryStatus: Equatable, Sendable {
    case unknown
    case valid(days: Int)
    case expired(days: Int)
}

struct ExpiryReminderPlan: Equatable, Sendable {
    let identifier: String
    let milestone: ExpiryMilestone
    let trigger: NotificationDeliveryTrigger
    let notification: VexSignNotification
}

enum ExpiryReminderPlanner {
    /// Whole calendar days, including a partial final day. Using date components
    /// rather than 86,400-second division keeps the count correct across DST.
    static func daysUntil(_ date: Date, from now: Date, calendar: Calendar) -> Int {
        let today = calendar.dateInterval(of: .day, for: now)?.start ?? now
        let targetDay = calendar.dateInterval(of: .day, for: date)?.start ?? date
        return calendar.dateComponents([.day], from: today, to: targetDay).day ?? 0
    }

    static func status(for subject: ExpiryReminderSubject, now: Date, calendar: Calendar) -> ExpiryStatus {
        guard let expiry = subject.expiry else { return .unknown }
        let days = daysUntil(expiry, from: now, calendar: calendar)
        return days >= 0 ? .valid(days: days) : .expired(days: -days)
    }

    static func identifier(for subject: ExpiryReminderSubject, milestone: ExpiryMilestone) -> String {
        // The digest keeps an internal record UUID out of the notification ID
        // while remaining stable across launches and replacements.
        "com.vexsign.expiry.\(subject.kind.rawValue).\(VexSignNotificationService.digest(subject.referenceID)).\(milestone.rawValue)"
    }

    /// All future milestones are scheduled; if one or more are overdue, only
    /// the most urgent of them is delivered immediately.
    static func plans(
        for subject: ExpiryReminderSubject,
        configuration: ExpiryReminderConfiguration,
        now: Date,
        calendar: Calendar
    ) -> [ExpiryReminderPlan] {
        guard let expiry = subject.expiry else { return [] }
        var immediate: ExpiryReminderPlan?
        var future: [ExpiryReminderPlan] = []

        for milestone in ExpiryMilestone.allCases where configuration.isEnabled(milestone) {
            let fireDate = milestone == .expired
                ? expiry
                : calendar.date(byAdding: .day, value: -milestone.days, to: expiry) ?? expiry
            let notification = VexSignNotification(
                identifier: identifier(for: subject, milestone: milestone),
                topic: subject.kind.topic,
                title: milestone.title,
                body: milestone.body(name: subject.displayName),
                category: .expiry,
                delivery: .immediate,
                details: [
                    NotificationPayloadKey.route.rawValue: "certificates",
                    NotificationPayloadKey.milestone.rawValue: String(milestone.rawValue)
                ],
                isTimeSensitive: milestone == .expired
            )
            if fireDate <= now {
                // Keep only the most urgent missed milestone.
                if immediate == nil || milestone.rawValue < (immediate?.milestone.rawValue ?? Int.max) {
                    immediate = ExpiryReminderPlan(
                        identifier: notification.identifier,
                        milestone: milestone,
                        trigger: .immediate,
                        notification: notification
                    )
                }
            } else {
                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
                components.calendar = calendar
                let scheduled = VexSignNotification(
                    identifier: notification.identifier,
                    topic: notification.topic,
                    title: notification.title,
                    body: notification.body,
                    category: notification.category,
                    delivery: .calendar(components),
                    details: notification.details,
                    playsSound: notification.playsSound,
                    isTimeSensitive: notification.isTimeSensitive
                )
                future.append(ExpiryReminderPlan(
                    identifier: scheduled.identifier,
                    milestone: milestone,
                    trigger: scheduled.delivery,
                    notification: scheduled
                ))
            }
        }
        if let immediate { return [immediate] }
        return future.sorted { $0.milestone.rawValue > $1.milestone.rawValue }
    }
}

/// Applies plans through the one notification service. Never claims a
/// certificate was renewed: it only reports dates it was given.
@MainActor
final class ExpiryReminderScheduler {
    static let prefix = "com.vexsign.expiry."

    private let service: VexSignNotificationService
    private let preferences: NotificationPreferenceStore
    private let calendar: Calendar
    private let clock: () -> Date

    init(
        service: VexSignNotificationService = .shared,
        preferences: NotificationPreferenceStore? = nil,
        calendar: Calendar = .current,
        clock: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.preferences = preferences ?? service.preferences
        self.calendar = calendar
        self.clock = clock
    }

    /// Schedules reminders for all live subjects and cancels reminders for
    /// subjects that disappeared, were replaced or had their topic disabled.
    @discardableResult
    func reconcile(_ subjects: [ExpiryReminderSubject]) async -> Int {
        let now = clock()
        let liveIDs = Set(subjects.flatMap { subject in
            ExpiryMilestone.allCases.map { ExpiryReminderPlanner.identifier(for: subject, milestone: $0) }
        })
        let stale = (await service.pendingIdentifiers()).filter {
            $0.hasPrefix(Self.prefix) && !liveIDs.contains($0)
        }
        service.cancel(identifiers: stale)

        var posted = 0
        for subject in subjects {
            guard preferences.isEnabled(subject.kind.topic) else { continue }
            for plan in ExpiryReminderPlanner.plans(
                for: subject,
                configuration: preferences.preferences.expiryReminders,
                now: now,
                calendar: calendar
            ) {
                // Re-submitting a future request replaces it, so changed dates
                // do not stack. An already-due reminder is deduped for a week.
                let key = plan.trigger == .immediate ? "expiry|\(plan.identifier)" : nil
                if await service.post(plan.notification, dedupeContentKey: key) { posted += 1 }
            }
        }
        return posted
    }

    func cancel(subject: ExpiryReminderSubject) {
        service.cancel(identifiers: ExpiryMilestone.allCases.map {
            ExpiryReminderPlanner.identifier(for: subject, milestone: $0)
        })
    }

    /// DST-safe expiry status for the UI, using the same planner arithmetic.
    func status(for subject: ExpiryReminderSubject) -> ExpiryStatus {
        ExpiryReminderPlanner.status(for: subject, now: clock(), calendar: calendar)
    }
}
