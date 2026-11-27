//
//  NotificationPreferences.swift
//  VexSign
//
//  Persisted, typed preferences for notifications VexSign posts itself.
//
//  These are separate from the system's authorization switch: a user can allow
//  notifications in iOS and still not want download progress or maintenance
//  summaries. Every poster checks the matching topic before calling the
//  notification service, so turning a switch off really stops the requests.
//

import Foundation
import NimbleExtensions

enum NotificationTopic: String, Codable, CaseIterable, Hashable, Sendable {
    case certificateExpiry
    case profileExpiry
    case appUpdates
    case downloads
    case devices
    case backups
    case sources
    case maintenance

    var label: String {
        switch self {
        case .certificateExpiry: return .localized("Certificate expiry")
        case .profileExpiry: return .localized("Provisioning profile expiry")
        case .appUpdates: return .localized("App updates")
        case .downloads: return .localized("Downloads and installations")
        case .devices: return .localized("Device and pairing events")
        case .backups: return .localized("Backup and restore")
        case .sources: return .localized("Source changes")
        case .maintenance: return .localized("Maintenance summaries")
        }
    }

    var detail: String {
        switch self {
        case .certificateExpiry: return .localized("Reminders before a signing certificate expires.")
        case .profileExpiry: return .localized("Reminders before a provisioning profile expires.")
        case .appUpdates: return .localized("A newly discovered version or build of an installed app.")
        case .downloads: return .localized("Verified download, signing and installation outcomes.")
        case .devices: return .localized("Pairing, trust and connection changes reported by a device service.")
        case .backups: return .localized("Completion or failure of a backup or restore.")
        case .sources: return .localized("Source refresh results and repository changes.")
        case .maintenance: return .localized("A short summary after scheduled maintenance runs.")
        }
    }
}

/// Individual expiry milestones can be switched off independently of the
/// topic, because a 30-day warning and a final-day warning are different
/// promises to the user.
struct ExpiryReminderConfiguration: Codable, Equatable, Sendable {
    var days30: Bool = true
    var days14: Bool = true
    var days7: Bool = true
    var days1: Bool = true
    var expired: Bool = true

    func isEnabled(_ milestone: ExpiryMilestone) -> Bool {
        switch milestone {
        case .days30: return days30
        case .days14: return days14
        case .days7: return days7
        case .days1: return days1
        case .expired: return expired
        }
    }

    mutating func set(_ milestone: ExpiryMilestone, enabled: Bool) {
        switch milestone {
        case .days30: days30 = enabled
        case .days14: days14 = enabled
        case .days7: days7 = enabled
        case .days1: days1 = enabled
        case .expired: expired = enabled
        }
    }
}

struct NotificationPreferences: Codable, Equatable, Sendable {
    var topics: [NotificationTopic: Bool]
    var expiryReminders: ExpiryReminderConfiguration

    static let defaultTopics: [NotificationTopic: Bool] = Dictionary(
        uniqueKeysWithValues: NotificationTopic.allCases.map { ($0, $0 != .maintenance) }
    )
    static let `default` = NotificationPreferences(
        topics: defaultTopics,
        expiryReminders: ExpiryReminderConfiguration()
    )

    init(topics: [NotificationTopic: Bool], expiryReminders: ExpiryReminderConfiguration) {
        // Unknown keys in stored JSON are dropped; missing keys inherit the default.
        self.topics = Dictionary(uniqueKeysWithValues: NotificationTopic.allCases.map {
            ($0, topics[$0] ?? Self.defaultTopics[$0] ?? true)
        })
        self.expiryReminders = expiryReminders
    }

    func isEnabled(_ topic: NotificationTopic) -> Bool { topics[topic] ?? false }

    static func decode(from data: Data?) -> NotificationPreferences {
        guard let data,
              let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data) else { // try? ok: corrupt preferences fall back to defaults
            return .default
        }
        return decoded
    }
}

/// The one persisted store for these preferences. Tests inject an isolated
/// suite; production uses the standard suite shared by the app and extensions.
@MainActor
final class NotificationPreferenceStore: ObservableObject {
    static let storageKey = "VexSign.notifications.preferences.v1"

    @Published private(set) var preferences: NotificationPreferences {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = .decode(from: defaults.data(forKey: Self.storageKey))
    }

    func isEnabled(_ topic: NotificationTopic) -> Bool { preferences.isEnabled(topic) }

    func set(_ topic: NotificationTopic, enabled: Bool) {
        var updated = preferences
        updated.topics[topic] = enabled
        preferences = updated
    }

    func isExpiryMilestoneEnabled(_ milestone: ExpiryMilestone) -> Bool {
        preferences.expiryReminders.isEnabled(milestone)
    }

    func setExpiryMilestone(_ milestone: ExpiryMilestone, enabled: Bool) {
        var updated = preferences
        updated.expiryReminders.set(milestone, enabled: enabled)
        preferences = updated
    }

    func reset() { preferences = .default }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return } // try? ok: Codable preferences cannot fail
        defaults.set(data, forKey: Self.storageKey)
    }
}
