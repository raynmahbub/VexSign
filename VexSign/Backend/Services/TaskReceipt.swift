import Foundation
import NimbleExtensions

/// No app titles, subject identifiers, URLs, raw errors or private paths are
/// exported. Detailed errors remain selectable in the local task details.
enum TaskReceipt {
    static func report(for task: UnifiedTask) -> String {
        var lines = [
            "VexSign — " + .localized("Task receipt"),
            task.kind.title + " · " + task.phase.title,
            .localized("Started") + ": " + task.createdAt.ISO8601Format(),
            .localized("Last updated") + ": " + task.updatedAt.ISO8601Format()
        ]
        if let stage = task.failureStage {
            lines.append(.localized("Failure stage") + ": " + stage.title)
        }
        lines.append(outcome(for: task))
        if task.phase == .failed {
            lines.append(TaskRecoveryGuide.resolve(kind: task.kind, failureStage: task.failureStage).detail)
        }
        lines.append(.localized("App names, identifiers, file paths and raw errors are omitted from this report. No credentials or file contents are included."))
        return lines.joined(separator: "\n")
    }

    static func outcome(for task: UnifiedTask) -> String {
        if task.kind == .sign && task.phase == .completed {
            return .localized("Signing completed. This receipt does not confirm that the signed copy is still retained or installed on the device.")
        }
        if task.kind == .importIPA && task.phase == .completed {
            return .localized("Import completed. A stored copy is not proof of signing or device installation.")
        }
        return .localized("This receipt records the task outcome, not the current device installation state. Review Library app details for installation evidence.")
    }
}
