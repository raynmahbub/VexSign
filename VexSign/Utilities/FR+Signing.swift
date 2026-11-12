//
//  FR+Signing.swift
//  VexSign
//
//  Signing adapter over SigningService.
//

import Foundation
import Security
import UIKit
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift
import OSLog
import NimbleExtensions

extension FR {
    /// Adapter over `SigningService`.
    ///
    /// Existing call sites stay source-compatible through the defaulted progress callbacks.
    /// Signing is owned by a cancellable service rather than an unstructured task; callers can
    /// observe stage/compatibility events and cancel their own request ID.
    static func signPackageFile(
        _ app: AppInfoPresentable,
        using options: Options,
        icon: UIImage?,
        certificate: CertificatePair?,
        overridesBlockingPreflightIssues: Bool = false,
        notices: [String] = [],
        requestID: String = UUID().uuidString,
        onStage: ((SigningStage) -> Void)? = nil,
        onVerified: (() -> Void)? = nil,
        onCompatibilityRemoved: (([String]) -> Void)? = nil,
        completion: @escaping (Result<Signed, Error>) -> Void
    ) {
        let request = SigningRequest(
            id: requestID,
            app: app,
            options: options,
            icon: icon,
            certificate: certificate,
            overridesBlockingPreflightIssues: overridesBlockingPreflightIssues,
            notices: notices
        )

        Task { @MainActor in
            // Reject duplicates before changing the shared log or Live Activity.
            guard SigningService.shared.canStart(request) else {
                completion(.failure(SigningService.BusyError()))
                return
            }
            let log = SigningLog.shared

            // Re-signing with a different identity is legal, but it costs the user the in-place
            // update and the app's keychain data. The signing sheet asks before it
            // starts; the paths that never show a sheet — batch, Update All, automation — get
            // the same explanation in the log rather than silence.
            if
                let certificate,
                app.isSigned,
                let detail = CertificateIdentity.match(for: app, certificate: certificate).detail {
                log.warn(detail)
            }

            // One report for every path that signs, including the ones that never show a sheet.
            // It is logged rather than enforced here: the sheet asks the same question before it
            // offers Sign, and the identity rule that must never be excused is enforced by the
            // pipeline. Profile and entitlement findings that can still install are exactly what
            // "Sign Anyway" exists for, so turning this into a hard stop would remove that choice.
            let capability = SigningService.shared.capability(for: request)
            if !capability.issues.isEmpty {
                for line in capability.logLines {
                    log.warn(line)
                }
            }

            SigningLiveActivityManager.shared.start(appName: request.name)

            // Unified task pipeline: one record for the whole sign operation.
            let task = UnifiedTaskCenter.shared.begin(
                kind: .sign,
                title: request.name,
                subtitle: .localized("Signing"),
                phase: .signing,
                subjectID: app.uuid
            )

            var trace = TaskContext()
            trace.appVersion = TaskContext.versionToken(app.version)
            trace.importTaskID = (UnifiedTaskCenter.shared.tasks + UnifiedTaskCenter.shared.history).first {
                $0.context?.artifactID == app.uuid && app.uuid != nil && ($0.kind == .importIPA || $0.kind == .download)
            }?.id
            if let directory = Storage.shared.getAppDirectory(for: app),
               let info = NSDictionary(contentsOf: directory.appendingPathComponent("Info.plist")) {
                trace.appBuild = TaskContext.versionToken(info["CFBundleVersion"] as? String)
            }
            if let certificateID = certificate?.uuid {
                trace.certificateReference = TaskContext.fingerprint(Data(certificateID.utf8))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do { trace.optionsFingerprint = TaskContext.fingerprint(try encoder.encode(options)) }
            catch { log.warn("Could not record the signing-options fingerprint.") }
            task.context = trace

            let keepAlive = BackgroundTaskManager(
                taskName: "Signing",
                expirationTitle: .localized("Signing continuing"),
                expirationBody: .localized("The signing will continue when you reopen the app")
            )
            keepAlive.start()

            let started = SigningService.shared.sign(request) { event in
                switch event {
                case .stage(let stage):
                    onStage?(stage)
                    // The task record is the durable copy of the execution trace. The signing
                    // sheet is dismissed as soon as a run succeeds, and other flows sign without
                    // a sheet at all, so what actually ran has to be recorded here.
                    task.context?.recordSigningStage(stage)
                    SigningLiveActivityManager.shared.update(progress: stage.progress, status: stage.title)
                    UnifiedTaskCenter.shared.transition(task, to: .signing, progress: stage.progress)

                case .signatureVerified:
                    onVerified?()
                    task.context?.recordSigningVerification()

                case .compatibilityRemoved(let components):
                    onCompatibilityRemoved?(components)

                case .finished(let signed):
                    keepAlive.stop()
                    log.success(.localized("Signed successfully"))
                    SigningLiveActivityManager.shared.complete(appName: request.name)
                    task.context?.artifactID = signed.uuid
                    task.context?.confirmationReason = "signature-verified-and-artifact-registered"
                    // Signing completed. This is the artifact being registered — never evidence
                    // that anything was installed.
                    task.context?.recordSigningOutcome(.completed)
                    UnifiedTaskCenter.shared.transition(task, to: .signed, progress: 1)
                    UnifiedTaskCenter.shared.transition(task, to: .completed, progress: 1)
                    completion(.success(signed))

                case .cancelled:
                    keepAlive.stop()
                    log.warn(.localized("Signing cancelled"))
                    SigningLiveActivityManager.shared.cancel()
                    task.context?.recordSigningOutcome(.cancelled)
                    UnifiedTaskCenter.shared.transition(task, to: .cancelled)
                    completion(.failure(CancellationError()))

                case .failed(let error):
                    task.context?.recordFailure(error)
                    task.context?.recordSigningOutcome(.failed)
                    keepAlive.stop()
                    log.error(error.localizedDescription)
                    SigningLiveActivityManager.shared.cancel()
                    UnifiedTaskCenter.shared.transition(task, to: .failed, error: error.localizedDescription)
                    completion(.failure(error))
                }
            }

            // The same app is already being signed: say so instead of queueing a second run that
            // would fight the first for the same work directory.
            if started == nil {
                keepAlive.stop()
                let error = SigningService.BusyError()
                log.error(error.localizedDescription)
                UnifiedTaskCenter.shared.transition(task, to: .failed, error: error.localizedDescription)
                completion(.failure(error))
            }
        }
    }
}