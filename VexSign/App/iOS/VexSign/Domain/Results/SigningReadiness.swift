import Foundation

/// One approval policy shared by the checklist, action panel and review sheet.
/// A selected certificate row is not proof of a usable key or a compatible profile.
/// Only the completed component/executable inspection can make signing ready.
struct SigningReadiness {
    enum State: Equatable, Sendable { case checking, ready, warning, blocked }

    let requiresIdentity: Bool
    let preflight: PreflightResult
    let evidence: SigningReviewEvidence?
    let auditFailure: String?
    var isChecking = false

    static func checking(requiresIdentity: Bool) -> Self {
        .init(requiresIdentity: requiresIdentity, preflight: .init(issues: []),
              evidence: nil, auditFailure: nil, isChecking: true)
    }

    var resolution: SigningResolutionReview? { evidence?.resolution }
    var identitiesValidated: Bool {
        resolution?.isReady == true && resolution?.authorization != nil
    }
    var warningCount: Int {
        preflight.issues.count + (resolution?.inventoryNotices.count ?? 0)
            + (resolution?.plannedRemovals.count ?? 0)
    }
    var state: State {
        if isChecking { return .checking }
        guard auditFailure == nil, let evidence, !preflight.hasMandatoryFailure,
              evidence.report.blocking.isEmpty,
              !requiresIdentity || identitiesValidated else { return .blocked }
        return warningCount == 0 ? .ready : .warning
    }
    /// Nonmandatory risks still require separate explicit confirmation in review.
    var canApprove: Bool { state == .ready || state == .warning }
}
