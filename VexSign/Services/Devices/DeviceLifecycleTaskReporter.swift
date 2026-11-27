// MARK: - Lifecycle task reporting
//
// The unified task center remains the only task owner. Device services speak to it through a
// narrow ID-based port, so no mutable UnifiedTask reference escapes into presentation code or
// across actor boundaries.

import Foundation

@MainActor
final class DeviceLifecycleTaskReporter {
    private let center: UnifiedTaskCenter
    /// Reservation is separate from the task list: `begin` can adopt a queued task,
    /// so checking `inFlight` immediately before it is not atomic. Two double-taps
    /// could otherwise share one task ID and run the same device operation twice.
    private var reservedSubjects: Set<String> = []
    private var subjectByTaskID: [String: String] = [:]

    init(center: UnifiedTaskCenter) {
        self.center = center
    }

    /// Returns nil when a device operation for this subject is already reserved.
    /// The reservation and task creation happen without an actor hop, so concurrent
    /// callers on the main actor cannot both win for the same subject.
    @discardableResult
    func beginOnce(kind: UnifiedTaskKind,
                   title: String,
                   subtitle: String?,
                   subjectID: String) async -> String? {
        guard reservedSubjects.insert(subjectID).inserted else { return nil }
        let taskID = await center.beginTaskID(kind: kind, title: title,
                                              subtitle: subtitle, subjectID: subjectID)
        subjectByTaskID[taskID] = subjectID
        return taskID
    }

    @discardableResult
    func begin(kind: UnifiedTaskKind, title: String, subtitle: String?, subjectID: String) async -> String {
        await center.beginTaskID(kind: kind, title: title, subtitle: subtitle, subjectID: subjectID)
    }

    func inFlight(kind: UnifiedTaskKind = .deviceSetup, subjectID: String) async -> Bool {
        let tasks = await center.tasks
        return TaskSubmissionPolicy.inFlight(kind: kind, subjectID: subjectID, in: tasks) != nil
    }

    func transition(id: String, to phase: UnifiedTaskPhase, progress: Double? = nil, error: String? = nil) async {
        await center.transitionTask(id: id, to: phase, progress: progress, error: error)
        if phase.isTerminal, let subject = subjectByTaskID.removeValue(forKey: id) {
            reservedSubjects.remove(subject)
        }
    }

    func update(id: String, progress: Double) async {
        await center.updateTask(id: id, progress: progress)
    }

    /// Native device stages have no byte counts. Reporting them as a percentage would invent
    /// progress, so they are mapped to ordered task phases with an indeterminate value.
    func report(stage: DeviceConnectionStage, for id: String) async {
        let phase: UnifiedTaskPhase
        switch stage {
        case .inspectingRecord: phase = .inspectingPairing
        case .checkingTransport: phase = .checkingTransport
        case .openingTunnel, .discoveringServices: phase = .discoveringServices
        case .queryingDevice, .authorized: phase = .queryingDevice
        case .disconnecting: return
        }
        await transition(id: id, to: phase, progress: -1)
    }
}
