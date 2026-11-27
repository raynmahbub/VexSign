//
//  NotificationModels.swift
//  VexSign
//
//  Value types shared by every notification poster. A caller describes what
//  happened in allow-listed fields; the service turns that into a request.
//  Nothing here accepts a dictionary of arbitrary data, which is what keeps
//  passwords, tokens and device identifiers out of lock-screen payloads.
//

import Foundation
import UserNotifications
import NimbleExtensions

// MARK: - Requests

enum NotificationDeliveryTrigger: Equatable, Sendable {
    case immediate
    case calendar(DateComponents)
    case after(TimeInterval)
}

struct VexSignNotification: Equatable, Sendable {
    /// Stable across launches and re-checks. Repeated posts replace one banner
    /// instead of stacking duplicates in Notification Center.
    let identifier: String
    let topic: NotificationTopic
    let title: String
    let body: String
    let category: VexSignNotificationCategory
    let delivery: NotificationDeliveryTrigger
    /// Allow-listed metadata only. Keys are enumerated by `NotificationPayloadKey`.
    let details: [String: String]
    let playsSound: Bool
    let isTimeSensitive: Bool

    init(
        identifier: String,
        topic: NotificationTopic,
        title: String,
        body: String,
        category: VexSignNotificationCategory,
        delivery: NotificationDeliveryTrigger = .immediate,
        details: [String: String] = [:],
        playsSound: Bool = true,
        isTimeSensitive: Bool = false
    ) {
        self.identifier = identifier
        self.topic = topic
        self.title = title
        self.body = body
        self.category = category
        self.delivery = delivery
        self.details = details
        self.playsSound = playsSound
        self.isTimeSensitive = isTimeSensitive
    }
}

enum NotificationPayloadKey: String, CaseIterable, Sendable {
    case route
    case referenceID
    case milestone
    case version
    case build
    case bundleID
    case outcome
}

// MARK: - Categories and actions

enum VexSignNotificationCategory: String, Sendable, CaseIterable {
    case expiry
    case update
    case task
    case source
    case maintenance

    var identifier: String { "com.vexsign.notification.\(rawValue)" }

    var actionIdentifiers: [String] {
        switch self {
        case .expiry: [NotificationAction.review.rawValue, NotificationAction.dismiss.rawValue]
        case .update: [NotificationAction.reviewUpdates.rawValue, NotificationAction.dismiss.rawValue]
        case .task: [NotificationAction.reviewTasks.rawValue, NotificationAction.dismiss.rawValue]
        case .source: [NotificationAction.reviewSources.rawValue, NotificationAction.dismiss.rawValue]
        case .maintenance: [NotificationAction.reviewTasks.rawValue, NotificationAction.dismiss.rawValue]
        }
    }

    var unNotificationCategory: UNNotificationCategory {
        let actions = actionIdentifiers.map { identifier in
            UNNotificationAction(
                identifier: identifier,
                title: NotificationAction(identifier: identifier)?.title ?? .localized("Open VexSign"),
                options: identifier == NotificationAction.dismiss.rawValue ? [.destructive] : [.foreground]
            )
        }
        return UNNotificationCategory(
            identifier: identifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }
}

enum NotificationAction: String, Sendable {
    init?(identifier: String) { self.init(rawValue: identifier) }

    case review = "com.vexsign.action.review"
    case dismiss = "com.vexsign.action.dismiss"
    case reviewUpdates = "com.vexsign.action.reviewUpdates"
    case reviewTasks = "com.vexsign.action.reviewTasks"
    case reviewSources = "com.vexsign.action.reviewSources"

    var title: String {
        switch self {
        case .review: return .localized("Review")
        case .dismiss: return .localized("Dismiss")
        case .reviewUpdates: return .localized("Review updates")
        case .reviewTasks: return .localized("Open tasks")
        case .reviewSources: return .localized("Review sources")
        }
    }
}

/// Where an action or notification tap takes the user. No action performs
/// signing, installing, updating or deleting by itself.
enum NotificationRoute: Equatable, Sendable {
    case certificates
    case updates
    case tasks
    case sources
    case none

    static func from(details: [String: String], actionIdentifier: String?) -> NotificationRoute {
        if actionIdentifier == NotificationAction.dismiss.rawValue { return .none }
        if actionIdentifier == NotificationAction.reviewUpdates.rawValue { return .updates }
        if actionIdentifier == NotificationAction.reviewTasks.rawValue { return .tasks }
        if actionIdentifier == NotificationAction.reviewSources.rawValue { return .sources }
        if actionIdentifier == NotificationAction.review.rawValue {
            return from(details: details, actionIdentifier: nil)
        }
        switch details[NotificationPayloadKey.route.rawValue] {
        case "certificates": return .certificates
        case "updates": return .updates
        case "tasks": return .tasks
        case "sources": return .sources
        default: return .none
        }
    }
}

// MARK: - History and dedupe

struct NotificationHistoryEntry: Codable, Equatable, Sendable {
    let identifier: String
    let topic: NotificationTopic
    let title: String
    let body: String
    let deliveredAt: Date
}

@MainActor
final class NotificationHistoryStore: ObservableObject {
    static let storageKey = "VexSign.notifications.history.v1"
    static let limit = 50

    @Published private(set) var entries: [NotificationHistoryEntry]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([NotificationHistoryEntry].self, from: data) { // try? ok: corrupt history starts empty instead of blocking notifications
            entries = Array(decoded.suffix(Self.limit))
        } else {
            entries = []
        }
    }

    func record(_ notification: VexSignNotification, at date: Date) {
        let entry = NotificationHistoryEntry(
            identifier: notification.identifier,
            topic: notification.topic,
            title: notification.title,
            body: notification.body,
            deliveredAt: date
        )
        entries = Array((entries + [entry]).suffix(Self.limit))
        guard let data = try? JSONEncoder().encode(entries) else { return } // try? ok: Codable entries cannot fail; history is best effort
        defaults.set(data, forKey: Self.storageKey)
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: Self.storageKey)
    }
}

/// Persisted, hashed dedupe keys. Values are never stored: only a digest of
/// the stable identifier plus a topic-specific content key, with a timestamp
/// so an old event can become news again after the window expires.
struct NotificationDedupeRecord: Codable, Equatable, Sendable {
    let digest: String
    let lastPostedAt: Date
}

@MainActor
final class NotificationDedupeStore {
    static let storageKey = "VexSign.notifications.dedupe.v1"
    static let limit = 100
    static let defaultWindow: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let window: TimeInterval
    private var records: [NotificationDedupeRecord]

    init(defaults: UserDefaults = .standard, window: TimeInterval = defaultWindow) {
        self.defaults = defaults
        self.window = window
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([NotificationDedupeRecord].self, from: data) { // try? ok: corrupt dedupe state starts empty
            records = Array(decoded.suffix(Self.limit))
        } else {
            records = []
        }
    }

    func isDuplicate(_ key: String, at now: Date) -> Bool {
        guard let record = records.first(where: { $0.digest == key }) else { return false }
        return now.timeIntervalSince(record.lastPostedAt) < window
    }

    @discardableResult
    func mark(_ key: String, at now: Date) -> Bool {
        records.removeAll { $0.digest == key }
        records.append(NotificationDedupeRecord(digest: key, lastPostedAt: now))
        records = Array(records.suffix(Self.limit))
        guard let data = try? JSONEncoder().encode(records) else { return false } // try? ok: Codable records cannot fail
        defaults.set(data, forKey: Self.storageKey)
        return true
    }

    func reset() {
        records = []
        defaults.removeObject(forKey: Self.storageKey)
    }
}
