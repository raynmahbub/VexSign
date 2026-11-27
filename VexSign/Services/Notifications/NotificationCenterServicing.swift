//
//  NotificationCenterServicing.swift
//  VexSign
//
//  A narrow interface around `UNUserNotificationCenter`. Production uses the
//  real center; deterministic tests use a recorder. This is a seam, not a
//  second notification manager — all posting decisions stay in
//  `VexSignNotificationService`.
//

import Foundation
import UserNotifications

protocol NotificationCenterServicing: AnyObject {
    func vxs_authorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void)
    func vxs_requestAuthorization(_ options: UNAuthorizationOptions,
                                  completion: @escaping (Bool, Error?) -> Void)
    func vxs_add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
    func vxs_removePending(_ identifiers: [String])
    func vxs_removeDelivered(_ identifiers: [String])
    func vxs_pendingRequests(_ completion: @escaping ([UNNotificationRequest]) -> Void)
    func vxs_deliveredNotifications(_ completion: @escaping ([UNNotification]) -> Void)
    func vxs_setCategories(_ categories: Set<UNNotificationCategory>)
    func vxs_setDelegate(_ delegate: UNUserNotificationCenterDelegate?)
}

extension UNUserNotificationCenter: NotificationCenterServicing {
    func vxs_authorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        getNotificationSettings { completion($0.authorizationStatus) }
    }

    func vxs_requestAuthorization(_ options: UNAuthorizationOptions,
                                  completion: @escaping (Bool, Error?) -> Void) {
        requestAuthorization(options: options, completionHandler: completion)
    }

    func vxs_add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        add(request, withCompletionHandler: completion)
    }

    func vxs_removePending(_ identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func vxs_removeDelivered(_ identifiers: [String]) {
        removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func vxs_pendingRequests(_ completion: @escaping ([UNNotificationRequest]) -> Void) {
        getPendingNotificationRequests(completionHandler: completion)
    }

    func vxs_deliveredNotifications(_ completion: @escaping ([UNNotification]) -> Void) {
        getDeliveredNotifications(completionHandler: completion)
    }

    func vxs_setCategories(_ categories: Set<UNNotificationCategory>) {
        setNotificationCategories(categories)
    }

    func vxs_setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        self.delegate = delegate
    }
}
