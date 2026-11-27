//
//  VexSignNotificationService.swift
//  VexSign
//
//  The single place that turns a VexSign event into a local notification.
//
//  DownloadManager, the self-updater, certificate monitoring and automation
//  still own *when* something happened; this service owns categories,
//  authorization, preferences, stable identifiers, dedupe, payload hygiene,
//  history, cancellation and action routing. Local notifications can appear
//  while the app is not running, but they cannot run our code: every action
//  only navigates once the user opens VexSign.
//

import Foundation
import UserNotifications
import CryptoKit
import UIKit
import os

extension Notification.Name {
    /// Sent when a notification or one of its actions should change the UI.
    static let vexNotificationRoute = Notification.Name("VexSign.notification.route")
}

@MainActor
final class VexSignNotificationService: NSObject, ObservableObject {
    static let shared = VexSignNotificationService()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    let preferences: NotificationPreferenceStore
    let history: NotificationHistoryStore
    private let dedupe: NotificationDedupeStore
    private let center: NotificationCenterServicing
    private let clock: () -> Date

    init(
        center: NotificationCenterServicing = UNUserNotificationCenter.current(),
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.preferences = NotificationPreferenceStore(defaults: defaults)
        self.history = NotificationHistoryStore(defaults: defaults)
        self.dedupe = NotificationDedupeStore(defaults: defaults)
        self.clock = clock
        super.init()
    }

    /// Idempotent. Call once from app launch, before any poster can run.
    func configure() {
        center.vxs_setDelegate(self)
        center.vxs_setCategories(Set(VexSignNotificationCategory.allCases.map(\.unNotificationCategory)))
        refreshAuthorizationStatus()
    }

    // MARK: - Authorization

    func refreshAuthorizationStatus() {
        center.vxs_authorizationStatus { [weak self] status in
            guard let self else { return }
            Task { @MainActor in self.authorizationStatus = status }
        }
    }

    /// Fresh authorization for a decision that must not rely on a cached value.
    func currentAuthorization() async -> UNAuthorizationStatus {
        let status = await withCheckedContinuation { continuation in
            center.vxs_authorizationStatus { continuation.resume(returning: $0) }
        }
        authorizationStatus = status
        return status
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let result = await withCheckedContinuation { continuation in
            center.vxs_requestAuthorization([.alert, .sound, .badge, .providesAppNotificationSettings]) {
                granted, _ in continuation.resume(returning: granted)
            }
        }
        refreshAuthorizationStatus()
        return result
    }

    nonisolated static func allowsDelivery(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    // MARK: - Posting

    /// Pure decision used by the service and by tests. `dedupeKey` is a hashed
    /// content key; `isDuplicate` is supplied so the decision needs no store.
    nonisolated static func shouldPost(
        _ notification: VexSignNotification,
        authorization: UNAuthorizationStatus,
        topicEnabled: Bool,
        dedupeKey: String?,
        isDuplicate: (String) -> Bool
    ) -> Bool {
        guard allowsDelivery(authorization), topicEnabled else { return false }
        guard !notification.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !notification.title.isEmpty, !notification.body.isEmpty else { return false }
        if let dedupeKey, isDuplicate(dedupeKey) { return false }
        return true
    }

    @discardableResult
    func post(_ notification: VexSignNotification, dedupeContentKey: String? = nil) async -> Bool {
        let key = dedupeContentKey.map { Self.digest(notification.identifier + "|" + $0) }
        guard Self.shouldPost(
            notification,
            authorization: authorizationStatus,
            topicEnabled: preferences.isEnabled(notification.topic),
            dedupeKey: key,
            isDuplicate: { [weak self] in self?.dedupe.isDuplicate($0, at: self?.clock() ?? Date()) ?? false }
        ) else { return false }

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: Self.content(for: notification),
            trigger: Self.trigger(for: notification.delivery)
        )
        return await deliver(request, topic: notification.topic, key: key, notification: notification)
    }

    /// Bridge for the existing notification builders (download progress and
    /// completion): they keep ownership of wording while the service keeps
    /// ownership of authorization, preferences, dedupe and history.
    @discardableResult
    func post(request: UNNotificationRequest, topic: NotificationTopic,
              dedupeContentKey: String? = nil) async -> Bool {
        let key = dedupeContentKey.map { Self.digest(request.identifier + "|" + $0) }
        let probe = VexSignNotification(
            identifier: request.identifier, topic: topic, title: request.content.title,
            body: request.content.body, category: .task, delivery: .immediate
        )
        guard Self.shouldPost(
            probe,
            authorization: authorizationStatus,
            topicEnabled: preferences.isEnabled(topic),
            dedupeKey: key,
            isDuplicate: { [weak self] in self?.dedupe.isDuplicate($0, at: self?.clock() ?? Date()) ?? false }
        ) else { return false }
        return await deliver(request, topic: topic, key: key, notification: probe)
    }

    private func deliver(_ request: UNNotificationRequest, topic: NotificationTopic,
                         key: String?, notification: VexSignNotification) async -> Bool {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                center.vxs_add(request) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            Logger.misc.error("Notification request failed: \(error.localizedDescription)")
            return false
        }
        if let key { dedupe.mark(key, at: clock()) }
        history.record(notification, at: clock())
        return true
    }

    /// A notification whose due time has already passed is posted immediately
    /// instead of being handed to the system with a trigger in the past.
    nonisolated static func trigger(for delivery: NotificationDeliveryTrigger) -> UNNotificationTrigger? {
        switch delivery {
        case .immediate: return nil
        case .after(let interval):
            return UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 1), repeats: false)
        case .calendar(let components):
            return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }
    }

    nonisolated static func content(for notification: VexSignNotification) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = notification.category.identifier
        content.threadIdentifier = notification.category.identifier
        content.userInfo = sanitized(notification.details)
        content.sound = notification.playsSound ? .default : nil
        if #available(iOS 15.0, *) {
            content.interruptionLevel = notification.isTimeSensitive ? .timeSensitive : (notification.playsSound ? .active : .passive)
        }
        return content
    }

    /// Allow-list + shape checks. A caller cannot smuggle a secret through an
    /// unrecognised key, and values that look like credentials or identifiers
    /// are dropped rather than truncated into the payload.
    nonisolated static func sanitized(_ details: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in NotificationPayloadKey.allCases where key != .referenceID {
            guard let raw = details[key.rawValue], !raw.isEmpty else { continue }
            let value = String(raw.prefix(160))
            guard !looksSensitive(value) else { continue }
            result[key.rawValue] = value
        }
        if let route = details[NotificationPayloadKey.route.rawValue],
           ["certificates", "updates", "tasks", "sources"].contains(route) {
            result[NotificationPayloadKey.route.rawValue] = route
        }
        return result
    }

    nonisolated static func looksSensitive(_ value: String) -> Bool {
        let patterns = [
            "(?i)(password|passphrase|token|secret|bearer|authorization|private.?key)",
            "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            "(?i)^[0-9a-f]{40,}$"
        ]
        return patterns.contains { value.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cancellation

    func cancel(identifier: String) {
        center.vxs_removePending([identifier])
        center.vxs_removeDelivered([identifier])
    }

    func cancel(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.vxs_removePending(identifiers)
        center.vxs_removeDelivered(identifiers)
    }

    /// Cancels both pending and delivered requests belonging to one stable
    /// subject, e.g. when a certificate is removed or replaced.
    func cancel(prefix: String) {
        center.vxs_pendingRequests { [weak self] requests in
            let matching = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            guard !matching.isEmpty else { return }
            Task { @MainActor in self?.center.vxs_removePending(matching) }
        }
        center.vxs_deliveredNotifications { [weak self] notifications in
            let matching = notifications.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            guard !matching.isEmpty else { return }
            Task { @MainActor in self?.center.vxs_removeDelivered(matching) }
        }
    }

    /// Clears only VexSign's own download banners. Foregrounding used to call
    /// `removeAllDeliveredNotifications`, which also wiped expiry and update
    /// alerts the user had not read yet.
    func clearDownloadNotifications() {
        let isDownloadID: (String) -> Bool = { $0 == "merged_download_progress" || $0.hasPrefix("completion_") }
        center.vxs_pendingRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter(isDownloadID)
            guard !ids.isEmpty else { return }
            Task { @MainActor in self?.center.vxs_removePending(ids) }
        }
        center.vxs_deliveredNotifications { [weak self] notifications in
            let ids = notifications.map(\.request.identifier).filter(isDownloadID)
            guard !ids.isEmpty else { return }
            Task { @MainActor in self?.center.vxs_removeDelivered(ids) }
        }
    }

    func pendingIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            center.vxs_pendingRequests { continuation.resume(returning: $0.map(\.identifier)) }
        }
    }

    // MARK: - Routing

    nonisolated static func route(for response: UNNotificationResponse) -> NotificationRoute {
        var details: [String: String] = [:]
        for pair in response.notification.request.content.userInfo {
            if let key = pair.key as? String, let value = pair.value as? String {
                details[key] = value
            }
        }
        return NotificationRoute.from(details: details, actionIdentifier: response.actionIdentifier)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension VexSignNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let playsSound = notification.request.content.sound != nil
        var options: UNNotificationPresentationOptions = [.banner, .badge]
        if playsSound { options.insert(.sound) }
        completionHandler(options)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = Self.route(for: response)
        if route != .none {
            NotificationCenter.default.post(
                name: .vexNotificationRoute,
                object: nil,
                userInfo: ["route": route]
            )
        }
        completionHandler()
    }
}
