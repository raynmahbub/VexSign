//
//  PackageSigningCoordinator.swift
//  VexSign
//
//  Coordinated signing workflow adapter over SigningService.
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

enum PackageSigningCoordinator {
    /// Coordinates signing requests over `SigningService` with unified preflight,
    /// identity compatibility reporting, Live Activity updates, and durable task tracing.
    static func signPackage(
        _ app: AppInfoPresentable,
        using options: Options,
        icon: UIImage?,
        certificate: CertificatePair?,
        overridesBlockingPreflightIssues: Bool = false,
        notices: [String] = [],
        requestID: String = UUID().uuidString,
        reviewedAuthorization: SigningResolutionAuthorization? = nil,
        isCancellationRequested: @escaping @MainActor () -> Bool = { false },
        onStage: (@MainActor (SigningStage) -> Void)? = nil,
        onVerified: (@MainActor () -> Void)? = nil,
        onCompatibilityRemoved: (@MainActor ([String]) -> Void)? = nil,
        completion: @escaping @MainActor (Result<Signed, Error>) -> Void
    ) {
        let initialRequest = SigningRequest(
            id: requestID,
            app: app,
            options: options,
            icon: icon,
            certificate: certificate,
            overridesBlockingPreflightIssues: overridesBlockingPreflightIssues,
            notices: notices
        )

        Task { @MainActor in
            var request = initialRequest
            guard !isCancellationRequested() else {
                completion(.failure(CancellationError()))
                return
            }
            if options.signingOption == .default {
                do {
                    guard let bundle = Storage.shared.getAppDirectory(for: app) else { throw SigningFileHandlerError.appNotFound }
                    let inventory = try SigningIdentityStore.snapshot()
                    let preferred = certificate?.objectID.uriRepresentation().absoluteString
                    let device = PairingBridge.inspectPairingRecord().udid
                    let worker = Task.detached(priority: .userInitiated) {
                        try SigningResolutionSession.review(bundle: bundle, options: options, inventory: inventory,
                            preferredIdentity: preferred, deviceUDID: device)
                    }
                    let review = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard !isCancellationRequested() else { throw CancellationError() }
                    guard review.isReady, let identityID = review.mainIdentityReference else {
                        throw SigningResolutionSession.refusal(review)
                    }
                    if let reviewedAuthorization, reviewedAuthorization != review.authorization {
                        throw SigningResolutionSession.changedSinceReview(from: reviewedAuthorization, to: review.authorization)
                    }
                    if !review.plannedRemovals.isEmpty && reviewedAuthorization == nil {
                        throw SigningFileHandlerError.identityRejected("Open Ready to Sign and explicitly confirm the listed optional extension removals. Automation cannot silently remove a newly incompatible extension.")
                    }
                    let resolvedCertificate = try Storage.shared.managedCertificate(id: identityID)
                    request = SigningRequest(id: requestID, app: app, options: options, icon: icon,
                        certificate: resolvedCertificate, overridesBlockingPreflightIssues: overridesBlockingPreflightIssues,
                        notices: notices)
                    request.authorization = review.authorization
                } catch {
                    SigningLog.shared.error(LogRedaction.redact(error.localizedDescription))
                    completion(.failure(error))
                    return
                }
            }
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
                let certificate = request.certificate,
                app.isSigned,
                let detail = CertificateIdentity.match(for: app, certificate: certificate).detail {
                log.warn(detail)
            }

            // One report for every path that signs, including the ones that never show a sheet.
            // Findings the user may accept are logged; the ones that make the result
            // uninstallable stop the run just below.
            let capability = SigningService.shared.capability(for: request)
            if !capability.issues.isEmpty {
                for line in capability.logLines {
                    log.warn(line)
                }
            }

            // Requirements iOS enforces at install are refused here, before a task record,
            // a Live Activity or a working copy exists. Every caller comes through this
            // function, so batch, Update All, Shortcuts and automation get the same answer
            // as the sheet, and get it before the long sign instead of after it.
            if let refusal = capability.refusal {
                log.error(refusal.localizedDescription)
                completion(.failure(refusal))
                return
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
            if let certificateID = request.certificate?.uuid {
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

            var terminal = false
            let started = SigningService.shared.sign(request) { event in
                guard !terminal else { return }
                if event.isTerminal { terminal = true }
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
                    // Read the value before mutating the optional context: Swift's
                    // writeback access must not overlap another read of that value.
                    let signatureWasVerified = task.context?.signingTrace?.verified == true
                    task.context?.confirmationReason = signatureWasVerified
                        ? "signature-verified-and-artifact-registered" : "artifact-registered-without-signature-verdict"
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
            if started == nil, !terminal {
                terminal = true
                keepAlive.stop()
                let error = SigningService.BusyError()
                log.error(error.localizedDescription)
                UnifiedTaskCenter.shared.transition(task, to: .failed, error: error.localizedDescription)
                completion(.failure(error))
            }
        }
    }
}
