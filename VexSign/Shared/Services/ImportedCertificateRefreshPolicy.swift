//
//  ImportedCertificateRefreshPolicy.swift
//  VexSign
//
//  Imported material does not have a seven-day refresh cadence. Its deadline is
//  the earlier of the leaf certificate and profile expiry, and revocation is a
//  warning that no refresh can repair. A scheduled pass may warn about those
//  dates; it never queues a weekly refresh for an imported identity.
//

import Foundation

enum ImportedCertificateWarning: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case expired = 1
    case revoked = 2
    case critical = 3
    case soon = 4
    case notice = 5

    var requiresAttention: Bool { self != .none }
}

enum ImportedCertificateRefreshPolicy {
    static let criticalDays = 3
    static let soonDays = 7
    static let noticeDays = 14

    /// No imported identity has a periodic refresh job, whatever its source.
    static func schedulesPeriodicRefresh(for kind: SigningCredentialKind) -> Bool {
        switch kind {
        case .importedPair, .cloud, .managed, .appleAccount: return false
        }
    }

    static func warning(for credential: SigningCredential, now: Date) -> ImportedCertificateWarning {
        if credential.isRevoked { return .revoked }
        guard credential.effectiveExpiry.timeIntervalSince1970.isFinite else { return .none }
        return warning(
            daysRemaining: Int(floor(credential.effectiveExpiry.timeIntervalSince(now) / 86_400)),
            isRevoked: false
        )
    }

    static func warning(for plan: RenewalPlan) -> ImportedCertificateWarning {
        warning(daysRemaining: plan.daysRemaining, isRevoked: plan.isRevoked)
    }

    static func warning(daysRemaining: Int, isRevoked: Bool) -> ImportedCertificateWarning {
        if isRevoked { return .revoked }
        if daysRemaining < 0 { return .expired }
        if daysRemaining <= criticalDays { return .critical }
        if daysRemaining <= soonDays { return .soon }
        if daysRemaining <= noticeDays { return .notice }
        return .none
    }

    /// Stable escalation levels for the local reminder store: a later, more
    /// urgent level may post again; an equal or less urgent one may not.
    static func notificationLevel(for warning: ImportedCertificateWarning) -> Int {
        switch warning {
        case .none: return 4
        case .notice: return 3
        case .soon: return 2
        case .critical: return 1
        case .expired, .revoked: return 0
        }
    }
}
