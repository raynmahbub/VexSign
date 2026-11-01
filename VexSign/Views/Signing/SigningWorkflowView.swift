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

    func status(reached: Set<SigningStage>, current: SigningStage?, running: Bool,
                succeeded: Bool, failed: Bool, cancelled: Bool) -> Status {
        if self == .install { return .separate }
        let wasReached = reached.contains { SigningWorkspaceStep(stage: $0) == self }
        guard wasReached else { return .pending }
        if let current, SigningWorkspaceStep(stage: current) == self {
            if running { return .active }
            if failed { return .failed }
            if cancelled { return .cancelled }
            return succeeded ? .completed : .pending
        }
        return .completed
    }
}

struct SigningWorkflowView: View {
    let reached: Set<SigningStage>
    let current: SigningStage?
    let running: Bool
    let succeeded: Bool
    let failed: Bool
    let cancelled: Bool

    private func statusColor(_ status: SigningWorkspaceStep.Status) -> Color {
        switch status {
        case .failed: return .red
        case .completed: return .green
        case .active: return Theme.tint
        default: return .secondary
        }
    }

    var body: some View {
        DisclosureGroup(.localized("Signing workflow")) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                ForEach(SigningWorkspaceStep.allCases) { step in
                    let status = step.status(reached: reached, current: current, running: running,
                                             succeeded: succeeded, failed: failed, cancelled: cancelled)
                    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                        Image(systemName: status.icon)
                            .foregroundStyle(statusColor(status))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                            Text(step.title).font(.subheadline.weight(.semibold))
                            Text(status.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(.localized("Only observed signing stages are marked complete. Installation is tracked separately; signing does not confirm that the app is installed."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, Theme.Spacing.small)
        }
    }
}
