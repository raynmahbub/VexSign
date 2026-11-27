// MARK: - Signing identity lifecycle
//
// Deterministic policy for expiry, refresh, replacement and cleanup. Storage
// mutations themselves stay in the existing vault / Core Data owners; this
// service only decides what is safe to do and reports orphaned Keychain tags.

import Foundation

enum SigningIdentityLifecycleAction: Equatable, Sendable {
    case keep
    case notify(reason: String)
    case refresh(provider: SigningProviderID)
    case replaceValidIdentityPending
    case removeOrphanedKeychainEntry(id: String)
}

struct SigningIdentityLifecycleDecision: Equatable, Sendable {
    let identityID: String
    let actions: [SigningIdentityLifecycleAction]
    let preservedValidIdentities: [String]
}

enum SigningIdentityLifecycle {
    static func decision(
        for identity: UnifiedSigningIdentity,
        validIdentityIDs: Set<String>,
        providerStatus: SigningProviderStatus?,
        now: Date = Date()
    ) -> SigningIdentityLifecycleDecision {
        var actions: [SigningIdentityLifecycleAction] = []
        let preserved = validIdentityIDs.filter { $0 != identity.id }.sorted()

        switch identity.validityState {
        case .valid, .unknown:
            actions.append(.keep)
        case .expiringSoon:
            actions.append(.notify(reason: "The identity is close to expiry. Keep the existing valid identity until a replacement is validated."))
            if let providerStatus, providerStatus.state == .available,
               let id = identity.providerID,
               canRefresh(id) {
                actions.append(.refresh(provider: id))
            }
        case .expired, .revoked, .keyMissing:
            actions.append(.notify(reason: "The identity is \(identity.validityState.displayName.lowercased()). Signing with it is blocked."))
            if identity.providerID != nil {
                actions.append(.replaceValidIdentityPending)
            }
        }

        return SigningIdentityLifecycleDecision(
            identityID: identity.id,
            actions: actions,
            preservedValidIdentities: preserved
        )
    }

    /// Only sources with an actual verified read workflow can refresh. Apple
    /// portal renewal stays in NativeSigning and is never faked here.
    private static func canRefresh(_ provider: SigningProviderID) -> Bool {
        guard let descriptor = SigningProviderRegistry.descriptors[provider] else { return false }
        return descriptor.supports(.certificateList) && descriptor.supports(.certificateDownload)
    }

    /// Orphans are Keychain labels with no corresponding vault metadata row.
    /// Deleting metadata to make an orphan disappear is never allowed; only
    /// the keychain entry is a candidate, and only after an explicit decision.
    static func orphanedKeychainIDs(
        keychainLabels: Set<String>,
        vaultIDs: Set<String>
    ) -> [String] {
        let prefix = "com.vexsign.vault.identity."
        return keychainLabels.compactMap { label in
            guard label.hasPrefix(prefix) else { return nil }
            let id = String(label.dropFirst(prefix.count))
            return id.isEmpty || vaultIDs.contains(id) ? nil : id
        }.sorted()
    }

    static func cleanupPlan(orphanedIDs: [String]) -> [SigningIdentityLifecycleAction] {
        orphanedIDs.map { .removeOrphanedKeychainEntry(id: $0) }
    }

    /// A refresh failure never removes an existing usable identity. The only
    /// permitted state change is keeping the old row and reporting the failure.
    static func preservedAfterRefreshFailure(validIdentityIDs: Set<String>) -> Set<String> {
        validIdentityIDs
    }
}
