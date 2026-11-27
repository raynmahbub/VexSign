// MARK: - Container task reporting
//
// Keeps the shared task center behind a small service so presentation code does
// not consume the engine directly.

import Foundation

@MainActor
final class ContainerTaskReporter {
    private let center: UnifiedTaskCenter

    init(center: UnifiedTaskCenter = .shared) {
        self.center = center
    }

    func begin(title: String, subtitle: String, subjectID: String?) async -> String {
        await center.beginTaskID(kind: .containerOperation, title: title,
                                 subtitle: subtitle, subjectID: subjectID)
    }

    func transition(id: String, to phase: UnifiedTaskPhase, progress: Double? = nil, error: String? = nil) async {
        await center.transitionTask(id: id, to: phase, progress: progress, error: error)
    }
}
