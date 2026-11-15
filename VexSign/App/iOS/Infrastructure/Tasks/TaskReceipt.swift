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
        let reasons = ["import-registered", "signature-verified-and-artifact-registered", "artifact-registered-without-signature-verdict", "native-installation-completed", "paired-installed-version-not-verified", "paired-command-outcome-unknown", "historical-installation-not-verified", "device-confirmed-installed",
                       "pairing-record-imported", "pairing-record-deleted", "pairing-export-prepared-not-received", "fresh-device-query-not-installation", "fresh-app-inventory-not-installation",
                       "device-reports-other-version", "device-did-not-report-installed-app", "install-start-not-observed",
                       "installation-evidence-unavailable", "installation-monitoring-deadline", "guest-prepared-not-installed", "exported-not-installed", "cancelled", "operation-failed", "interrupted-process-exit", "monitoring-stopped-install-may-continue", "process-exit-installation-unconfirmed", "supported-installation-inventory-unavailable", "ota-completion-not-authoritative"]
        let exactObservationValid = context?.hasConfirmedInstallation(notAfter: task.updatedAt) == true
        if let reason = context?.confirmationReason, reasons.contains(reason),
           reason != "device-confirmed-installed" || exactObservationValid { lines.append("Result evidence: " + reason) }
        if task.kind == .install, exactObservationValid, let evidence = context?.installedApplicationEvidence {
            lines.append("Observed installed version/build: " + evidence.version + " (" + evidence.build + ")")
            lines.append("Observation source: coredevice-appservice")
            lines.append("Observed at: " + evidence.observedAt.ISO8601Format())
            lines.append("Device/record binding: matched (identifiers omitted)")
            if let digest = context?.installationPackageSHA256 { lines.append("Submitted archive SHA-256: " + digest) }
        }
        // Delivery, handoff and confirmation as separate lines, so a delivered package is
        // not read as an installed app. Written once the attempt has stopped.
        if task.kind == .install, task.phase.isTerminal {
            lines.append(contentsOf: evidence(for: task).receiptLines)
            if let checked = context?.lastReconciliationAt {
                lines.append("Last verification attempt: " + checked.ISO8601Format())
            }
        }
        // How many times the device was asked, so a receipt for an install that waited on
        // verification shows it was being checked rather than merely left open.
        if task.kind == .install, let checks = context?.verificationAttempts, (1...100_000).contains(checks) {
            lines.append("Installation checks: \(checks)")
        }
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

    /// The separated install evidence for a task record.
    static func evidence(for task: UnifiedTask) -> InstallEvidenceSummary {
        let unverifiedClaim = task.context?.confirmationReason == "device-confirmed-installed"
            && task.context?.hasConfirmedInstallation(notAfter: task.updatedAt) != true
        return InstallEvidenceSummary.resolve(
            method: task.context?.installationMethod,
            reason: unverifiedClaim ? "exact-installation-evidence-missing" : task.context?.confirmationReason,
            handedOff: task.context?.handoffAt != nil,
            historical: task.restoredFromHistory || unverifiedClaim
        )
    }

    static func outcome(for task: UnifiedTask) -> String {
        if task.kind == .deviceSetup {
            return .localized("This receipt records a pairing setup action only. File validity, a device identity query, signing, provisioning and exact installed-version confirmation are separate. No private record, device identifier or companion receipt is exported.")
        }
        if task.kind == .install && task.phase == .cancelled {
            return .localized("VexSign stopped its work and monitoring. An installation already accepted by iOS may continue; this report does not claim that iOS cancelled it.")
        }
        if task.kind == .install, task.context?.confirmationReason == "historical-installation-not-verified" {
            return .localized("This older task did not persist supported exact installed-version evidence. Its previous success label has been changed to unconfirmed. A missing handoff record does not prove nothing was sent; check the device before retrying.")
        }
        if task.phase == .unconfirmed, task.kind == .install, evidence(for: task).transport == .overTheAir {
            // Say what is and is not known, and which method does give an answer.
            return .localized("The package was handed to iOS, but the device did not report the result of this over-the-air installation, so this receipt cannot say whether the app was installed. Check the Home Screen before installing again; no reinstall was started. Paired installation also requires exact installed-version evidence and remains gated in this build.")
        }
        if task.phase == .unconfirmed {
            return .localized("VexSign has no supported exact installed-version result for this task. This receipt cannot say whether the app was installed. Check the Home Screen and app version before deciding whether to install again. No reinstall was started.")
        }
        if task.phase == .interrupted {
            return .localized("VexSign was interrupted. No signing or installation was restarted automatically. Check Signed Apps and the device before starting another attempt.")
        }
        if task.kind == .sign && (task.phase == .failed || task.phase == .cancelled) {
            // A run signs a working copy and registers a new one only when it succeeds. Without
            // this, the receipt of a re-sign that failed read as a verdict on the copy it was
            // started from, which is still exactly as it was.
            return .localized("This signing attempt did not produce a signed copy. The library copy it started from was not changed.")
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
