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

    /// What this method gives you, in the method picker.
    ///
    /// Free Apple ID deliberately does *not* say "Weekly refresh". Nothing in this build
    /// renews a profile: `NativeSigningManager.refreshRenewalCandidates` only lists the
    /// profiles that are close to expiring, and the audit register keeps that renewal
    /// behind an explicit grant that is not implemented. Advertising the refresh as a
    /// feature would promise the one thing the user has to do by hand.
    var shortDescription: String {
        switch self {
        case .paidCertificate: return .localized("No limits · 1 year · Full entitlements")
        case .freeAppleID: return .localized("3 apps / 7 days · Renew by hand each week")
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
/// Runtime availability of a signing path.
///
/// Only what the signing-methods screen renders: whether the method can be
/// selected and, when it cannot, why. Free-Apple-ID session/quota status
/// lives in `NativeSigningManager.snapshot`, which the same screen reads
/// directly — duplicating it here would drift (as the removed placeholder
/// fields did).
struct SigningMethodAvailability: Equatable {
    let isAvailable: Bool
    /// Why the method cannot be selected, or the caveat that applies when it can; `nil`
    /// exactly when the method is fully usable.
    let availabilityReason: String?

    static func current(for method: SigningMethod) -> SigningMethodAvailability {
        switch method {
        case .paidCertificate:
            let hasCert = !Storage.shared.getAllCertificates().isEmpty
            return SigningMethodAvailability(
                isAvailable: hasCert,
                availabilityReason: hasCert ? nil : .localized("Import a .p12 certificate and .mobileprovision profile")
            )
        case .freeAppleID:
            // Always selectable: choosing it starts sign-in, and the live session state is
            // rendered from NativeSigningManager's snapshot. It is not, however, equivalent to
            // an imported certificate while the native account adapter stays unintegrated, and
            // the picker is where the user should learn that.
            let registration = SigningMethodCapabilities.current.nativeAppleAccountSigning
            return SigningMethodAvailability(
                isAvailable: true,
                availabilityReason: registration == .notIntegrated
                    ? .localized("Experimental: account provisioning is not yet integrated with signing.")
                    : nil
            )
        case .trollStore:
            let available = TrollStoreDetector.isAvailable
            return SigningMethodAvailability(
                isAvailable: available,
                availabilityReason: available ? nil : TrollStoreDetector.unavailabilityReason
            )
        }
    }
}

// MARK: - TrollStoreDetector
/// Whether TrollStore can be used on this device, and what that answer is based on.
///
/// Every iOS device answers `canOpenURL("apple-magnifier://")` — it is Apple's
/// Magnifier scheme — so a scheme probe can never report "TrollStore is here".
/// The only positive evidence available to an app is TrollStore's own
/// `_TrollStore` marker next to its bundle, which is how TrollStore recognises
/// the apps it may replace in place. A normal (non-TrollStore) install cannot
/// read that directory, so this answers `false` there: it can confirm, never
/// prove absence of TrollStore.
enum TrollStoreDetector {
    static var isAvailable: Bool {
        TrollStoreHandoff.installedByTrollStore()
    }

    /// Why the method is unavailable, without implying TrollStore is not installed.
    static var unavailabilityReason: String {
        .localized("TrollStore was not detected for this install. VexSign can only tell when this copy of the app itself was installed by TrollStore; on any other install it cannot see TrollStore. Install the signed IPA from TrollStore directly.")
    }
}
