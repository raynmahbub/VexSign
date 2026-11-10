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
        let context = task.context
        lines.append("VexSign build: " + BuildIdentity.validatedVersion(context?.clientVersion))
        lines.append("Source commit: " + BuildIdentity.validatedCommit(context?.sourceCommit))
        if let version = TaskContext.versionToken(context?.appVersion) { lines.append("App version: " + version) }
        if let build = TaskContext.versionToken(context?.appBuild) { lines.append("App build: " + build) }
        if let method = context?.installationMethod, ["OTA", "paired-device", "guest-import", "export"].contains(method) {
            lines.append("Installation method: " + method)
        }
        for (label, value) in [("Certificate reference", context?.certificateReference), ("Options fingerprint", context?.optionsFingerprint)] {
            if let value, value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) {
                lines.append(label + ": " + value)
            }
        }
        let reasons = ["import-registered", "signature-verified-and-artifact-registered", "native-installation-completed", "device-confirmed-installed",
                       "device-reports-other-version", "device-did-not-report-installed-app", "install-start-not-observed",
                       "installation-evidence-unavailable", "guest-prepared-not-installed", "exported-not-installed", "cancelled", "operation-failed", "interrupted-process-exit", "monitoring-stopped-install-may-continue"]
        if let reason = context?.confirmationReason, reasons.contains(reason) { lines.append("Result evidence: " + reason) }
        // The signing engine's own trace, so a receipt can say which steps actually ran and
        // whether the signature was verified — not merely that the task reached a phase.
        if task.kind == .sign, let trace = context?.signingTrace, !trace.stages.isEmpty {
            lines.append(.localized("Signing stages") + ": " + trace.stages.map(\.title).joined(separator: " → "))
            if let verified = trace.verified {
                lines.append(.localized("Signature verification") + ": "
                    + (verified ? .localized("Passed") : .localized("Not reported")))
            }
        }
        if task.phase == .failed, let category = context?.errorCategory,
           ["network", "filesystem", "security", "operation"].contains(category), let code = context?.errorCode {
            lines.append("Error category/code: \(category) (\(code))")
        }
        for entry in task.stageHistory {
            let seconds = max(0, entry.date.timeIntervalSince(task.createdAt))
            lines.append(String(format: "+%.1fs — %@", seconds, entry.phase.title))
        }
        let duration = max(0, task.updatedAt.timeIntervalSince(task.createdAt))
        lines.append(String(format: "Elapsed: %.1fs", duration))
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
        if task.kind == .install && task.phase == .cancelled {
            return .localized("VexSign stopped its work and monitoring. An installation already accepted by iOS may continue; this report does not claim that iOS cancelled it.")
        }
        if task.phase == .unconfirmed {
            return .localized("VexSign finished, but iOS did not expose installation status, so this receipt cannot say whether the app was installed. Check the Home Screen and the app details in Library before installing again. No reinstall was started.")
        }
        if task.phase == .interrupted {
            return .localized("VexSign was interrupted. No signing or installation was restarted automatically. Check Signed Apps and the device before starting another attempt.")
        }
        if task.kind == .sign && task.phase == .completed {
            return .localized("Signing completed. This receipt does not confirm that the signed copy is still retained or installed on the device.")
        }
        if task.kind == .importIPA && task.phase == .completed {
            return .localized("Import completed. A stored copy is not proof of signing or device installation.")
        }
        return .localized("This receipt records the task outcome, not the current device installation state. Review Library app details for installation evidence.")
    }
}
