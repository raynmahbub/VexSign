// MARK: - SigningMethod
/// Represents the three distinct signing paths available in VexSign.
/// Each path has different capabilities, limits, and requirements.

import Foundation
import SwiftUI
import NimbleExtensions

enum SigningMethod: String, CaseIterable, Codable, Identifiable {
    /// Paid Apple Developer certificate (.p12 + .mobileprovision)
    /// - No app limit, 1-year expiry, full entitlement support
    case paidCertificate = "paid_certificate"

    /// Free Apple ID via SideSign (NativeSigning)
    /// - 3 apps per 7 days, requires weekly refresh, limited entitlements
    case freeAppleID = "free_apple_id"

    /// TrollStore (permanent installation, no certificate needed)
    /// - iOS 14.0-16.6.1 only, no signing required, permanent
    case trollStore = "troll_store"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paidCertificate: return .localized("Paid Certificate")
        case .freeAppleID: return .localized("Free Apple ID")
        case .trollStore: return .localized("TrollStore")
        }
    }

    var shortDescription: String {
        switch self {
        case .paidCertificate: return .localized("No limits · 1 year · Full entitlements")
        case .freeAppleID: return .localized("3 apps / 7 days · Weekly refresh")
        case .trollStore: return .localized("Permanent · No cert · iOS 14–16.6.1")
        }
    }

    var icon: String {
        switch self {
        case .paidCertificate: return "checkmark.seal.fill"
        case .freeAppleID: return "person.crop.circle.badge.plus"
        case .trollStore: return "t.square.fill"
        }
    }

    var requiresCredentials: Bool {
        switch self {
        case .paidCertificate: return true
        case .freeAppleID: return true
        case .trollStore: return false
        }
    }

    var supportsAutoRefresh: Bool {
        switch self {
        case .paidCertificate: return false // Certs don't auto-renew
        case .freeAppleID: return true // Profiles expire weekly
        case .trollStore: return false // Permanent
        }
    }

    var maxApps: Int? {
        switch self {
        case .paidCertificate: return nil // No limit
        case .freeAppleID: return 3
        case .trollStore: return nil // No limit
        }
    }

    var expiryDays: Int? {
        switch self {
        case .paidCertificate: return 365
        case .freeAppleID: return 7
        case .trollStore: return nil // Permanent
        }
    }
}

// MARK: - SigningMethodAvailability
/// Runtime availability and configuration status for each signing method.
struct SigningMethodAvailability: Equatable {
    let method: SigningMethod
    let isAvailable: Bool
    let availabilityReason: String?
    let configuredCredentials: Bool
    let activeAppCount: Int
    let canAddMoreApps: Bool

    static func current(for method: SigningMethod) -> SigningMethodAvailability {
        switch method {
        case .paidCertificate:
            let certs = Storage.shared.getAllCertificates()
            let hasCert = !certs.isEmpty
            return SigningMethodAvailability(
                method: method,
                isAvailable: hasCert,
                availabilityReason: hasCert ? nil : .localized("Import a .p12 certificate and .mobileprovision profile"),
                configuredCredentials: hasCert,
                activeAppCount: 0, // TODO: Count signed apps using paid cert
                canAddMoreApps: hasCert
            )
        case .freeAppleID:
            // TODO: Check NativeAccountBackend for active session
            return SigningMethodAvailability(
                method: method,
                isAvailable: true, // Always available if NativeSigning is linked
                availabilityReason: nil,
                configuredCredentials: false, // TODO: Check if signed in
                activeAppCount: 0, // TODO: Count apps signed with free Apple ID
                canAddMoreApps: true // TODO: Check 3-app limit
            )
        case .trollStore:
            let available = TrollStoreDetector.isAvailable
            return SigningMethodAvailability(
                method: method,
                isAvailable: available,
                availabilityReason: available ? nil : .localized("TrollStore not detected on this device"),
                configuredCredentials: false,
                activeAppCount: 0,
                canAddMoreApps: available
            )
        }
    }
}

// MARK: - TrollStoreDetector
/// Detects if TrollStore is installed and available for installation.
enum TrollStoreDetector {
    static var isAvailable: Bool {
        // Check for TrollStore's URL scheme or helper app
        // This is a simplified check; real implementation would use the
        // TrollStoreHelper framework or check for specific files/URL schemes
        if let url = URL(string: "trollstore://"), UIApplication.shared.canOpenURL(url) {
            return true
        }
        // Also check for TrollStore's entitlement injection capability
        // by looking for the helper at known paths
        return false
    }

    static func install(ipaURL: URL, completion: @escaping (Bool, Error?) -> Void) {
        // Use TrollStore's URL scheme to trigger installation
        // trollstore://install?url=<encoded_ipa_url>
        guard var components = URLComponents(url: URL(string: "trollstore://install")!, resolvingAgainstBaseURL: false) else {
            completion(false, NSError(domain: "VexSign", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid TrollStore URL"]))
            return
        }
        components.queryItems = [URLQueryItem(name: "url", value: ipaURL.absoluteString)]
        guard let installURL = components.url else {
            completion(false, NSError(domain: "VexSign", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create TrollStore install URL"]))
            return
        }
        UIApplication.shared.open(installURL) { success in
            completion(success, success ? nil : NSError(domain: "VexSign", code: -1, userInfo: [NSLocalizedDescriptionKey: "TrollStore installation failed or was cancelled"]))
        }
    }
}