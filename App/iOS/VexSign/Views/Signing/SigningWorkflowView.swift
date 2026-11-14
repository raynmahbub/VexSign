import SwiftUI
import NimbleExtensions

/// Presentation only: installation belongs to InstallQueue/the external installer.
/// A signing stage or success callback must never advance the installation step.
enum SigningWorkspaceStep: Int, CaseIterable, Identifiable {
    case prepare, customize, sign, verify, install

    var id: Int { rawValue }

    init(stage: SigningStage) {
        switch stage {
        case .copying: self = .prepare
        case .modifying, .thinning, .injecting: self = .customize
        case .signing: self = .sign
        case .verifying, .registering: self = .verify
        }
    }

    var title: String {
        switch self {
        case .prepare: return .localized("Prepare")
        case .customize: return .localized("Customize")
        case .sign: return .localized("Sign")
        case .verify: return .localized("Verify")
        case .install: return .localized("Install")
        }
    }

    enum Status: Equatable {
        case pending, active, completed, failed, cancelled, separate

        var title: String {
            switch self {
            case .pending: return .localized("Not run")
            case .active: return .localized("In progress")
            case .completed: return .localized("Completed")
            case .failed: return .localized("Failed")
            case .cancelled: return .localized("Cancelled")
            case .separate: return .localized("Separate installation step")
            }
        }

        var icon: String {
            switch self {
            case .pending: return "circle"
            case .active: return "circle.inset.filled"
            case .completed: return "checkmark.circle"
            case .failed: return "exclamationmark.circle"
            case .cancelled: return "stop.circle"
            case .separate: return "arrow.up.forward.app"
            }
        }
    }

    /// What this step shows, from the evidence one run actually produced.
    ///
    /// Nothing here is inferred from elapsed time or from the run succeeding overall:
    /// a step is `pending` ("Not run") until the engine reported a stage that maps to it,
    /// and `Verify` needs the engine's own verification result.
    func status(_ snapshot: SigningWorkflowSnapshot) -> Status {
        // Installation is a separate lifecycle. Signing can start it, never complete it.
        if self == .install { return .separate }

        let wasReached = snapshot.reached.contains { SigningWorkspaceStep(stage: $0) == self }
        guard wasReached else { return .pending }

        let isCurrent = snapshot.current.map { SigningWorkspaceStep(stage: $0) == self } ?? false

        // Where the run stopped is what the user needs to see, so a terminal outcome at this
        // step outranks completion evidence recorded earlier inside the same step: a run that
        // verified the signature and then failed registering the artifact failed at Verify.
        if isCurrent {
            // "Still running" is not an outcome, and it must not withhold evidence the system
            // already holds. Verification is a fact the engine established about the bundle, so
            // once it is recorded the step is complete even while the run goes on to register the
            // artifact — otherwise Verify reads as merely in progress for the whole window
            // between the engine's verdict and the next stage.
            if self == .verify, snapshot.verified, !snapshot.failed, !snapshot.cancelled {
                return .completed
            }
            if snapshot.running { return .active }
            if snapshot.failed { return .failed }
            if snapshot.cancelled { return .cancelled }
        }

        // Completion, per step, on evidence only:
        //   * Verify — the engine's own signature verification accepted the bundle.
        //   * The rest — the run reported a later stage, or finished successfully.
        if self == .verify {
            return snapshot.verified ? .completed : .pending
        }
        let movedPast = snapshot.reached.contains { SigningWorkspaceStep(stage: $0).rawValue > rawValue }
        return (movedPast || snapshot.succeeded) ? .completed : .pending
    }

    /// Compatibility entry point: the flags a live signing sheet already had.
    ///
    /// `succeeded` implies verification here because a run can only finish successfully when
    /// `_verifySignedBundle` accepted the bundle. Callers with the engine's own verdict — the
    /// signing sheet and any restored trace — should build a `SigningWorkflowSnapshot` and pass
    /// the explicit evidence instead.
    func status(reached: Set<SigningStage>, current: SigningStage?, running: Bool,
                succeeded: Bool, failed: Bool, cancelled: Bool) -> Status {
        status(SigningWorkflowSnapshot(reached: reached, current: current, running: running,
                                       succeeded: succeeded, verified: succeeded,
                                       failed: failed, cancelled: cancelled))
    }
}

// MARK: - Snapshot

/// Everything one signing run was observed to do, in one value.
///
/// Built either from the live signing sheet's state or from a persisted `TaskSigningTrace`, so
/// the workflow reads the same whether the run is in flight or finished a week ago. It is a value
/// with no view lifetime, which is what makes the trace survive the sheet being dismissed.
struct SigningWorkflowSnapshot: Equatable {
    /// Every stage the engine reported, in order.
    var reached: Set<SigningStage> = []
    /// The stage in flight, or the one the run stopped at.
    var current: SigningStage?
    var running = false
    var succeeded = false
    /// The engine's own signature-verification result. Distinct from `succeeded`.
    var verified = false
    var failed = false
    var cancelled = false

    init(
        reached: Set<SigningStage> = [],
        current: SigningStage? = nil,
        running: Bool = false,
        succeeded: Bool = false,
        verified: Bool = false,
        failed: Bool = false,
        cancelled: Bool = false
    ) {
        self.reached = reached
        self.current = current
        self.running = running
        self.succeeded = succeeded
        self.verified = verified
        self.failed = failed
        self.cancelled = cancelled
    }

    /// Restores the display state from a persisted trace alone.
    ///
    /// `stoppedAt` stays the current step even for a finished run: that is what puts a recorded
    /// failure or cancellation on the step it actually happened in.
    init(trace: TaskSigningTrace, running: Bool = false) {
        self.reached = Set(trace.stages)
        self.current = trace.stoppedAt
        self.running = running
        self.succeeded = trace.outcome == .completed
        self.verified = trace.verified ?? false
        self.failed = trace.outcome == .failed
        self.cancelled = trace.outcome == .cancelled
    }

    /// Nothing was ever observed — the honest starting point, and what a step with no evidence
    /// has to render as.
    var isEmpty: Bool {
        reached.isEmpty && current == nil && !running && !succeeded && !failed && !cancelled && !verified
    }

    func status(of step: SigningWorkspaceStep) -> SigningWorkspaceStep.Status { step.status(self) }

    /// The engine stages actually reported inside one step, in run order.
    ///
    /// A step groups several stages (Customize covers modifying, thinning and injecting), and
    /// a run only reports the ones it performs. Listing them shows what was done — a run
    /// with no tweaks never lists "Injecting tweaks" — without inventing a status for work
    /// that was skipped.
    func observedStages(in step: SigningWorkspaceStep) -> [SigningStage] {
        SigningStage.allCases.filter { reached.contains($0) && SigningWorkspaceStep(stage: $0) == step }
    }

    /// The ordered display rows, so a caller can render or assert the whole workflow.
    var steps: [(step: SigningWorkspaceStep, status: SigningWorkspaceStep.Status)] {
        SigningWorkspaceStep.allCases.map { (step: $0, status: $0.status(self)) }
    }
}

// MARK: - View

struct SigningWorkflowView: View {
    let snapshot: SigningWorkflowSnapshot
    /// A screen that shows more than one run has to say which run each trace belongs to.
    let title: String
    let identifier: String

    init(
        snapshot: SigningWorkflowSnapshot,
        title: String = .localized("Signing workflow"),
        identifier: String = A11y.Signing.workflow
    ) {
        self.snapshot = snapshot
        self.title = title
        self.identifier = identifier
    }

    private func statusColor(_ status: SigningWorkspaceStep.Status) -> Color {
        switch status {
        case .failed: return .red
        case .completed: return .green
        case .active: return Theme.tint
        default: return .secondary
        }
    }

    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                ForEach(SigningWorkspaceStep.allCases) { step in
                    let status = step.status(snapshot)
                    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                        Image(systemName: status.icon)
                            .foregroundStyle(statusColor(status))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                            Text(step.title).font(.subheadline.weight(.semibold))
                            Text(status.title).font(.caption).foregroundStyle(.secondary)
                            let stages = snapshot.observedStages(in: step)
                            if !stages.isEmpty {
                                Text(stages.map(\.title).joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(.localized("Only observed signing stages are marked complete. Installation is tracked separately; signing does not confirm that the app is installed."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, Theme.Spacing.small)
        }
        .accessibilityIdentifier(identifier)
    }
}
