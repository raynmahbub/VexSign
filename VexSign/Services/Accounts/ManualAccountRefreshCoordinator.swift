//
//  ManualAccountRefreshCoordinator.swift
//  VexSign
//
//  Runs one explicit account refresh in order. Each step is injected so the
//  workflow can be tested without Apple, Core Data, a signing engine or a device.
//  The production caller supplies the existing account adapter, the ordinary
//  certificate-signing pipeline, the install queue and an install-evidence probe.
//
//  A stage that fails or is cancelled ends the run. No later stage is attempted,
//  and an outcome is recorded for the stage that actually stopped it.
//

import Foundation

@MainActor
struct ManualAccountRefreshCoordinator {
    struct Steps {
        var now: @MainActor () -> Date = { Date() }
        var provision: @MainActor () async throws -> AccountRefreshReceipt
        var importIdentity: @MainActor () async throws -> AccountRefreshHandoff
        var sign: @MainActor (AccountRefreshHandoff) async throws -> AccountRefreshSignedArtifact
        var install: @MainActor (AccountRefreshSignedArtifact) async throws -> AccountRefreshInstallation
        var verify: @MainActor (AccountRefreshInstallation) async throws -> AccountRefreshVerification
        var record: OperationOutcomeRecording
    }

    enum Outcome: Equatable {
        case completed(AccountRefreshResult)
        case failed(AccountRefreshError)
    }

    private static let operation = "accountRefresh"

    func run(_ request: AccountRefreshRequest, steps: Steps) async -> Outcome {
        var startedAt = steps.now()
        do {
            try Task.checkCancellation()
            try AccountRefreshPlanner.validatePreflight(request, now: startedAt)
            await record(request, stage: .preflight, status: .succeeded, reason: nil, startedAt: startedAt, steps: steps)
        } catch {
            return await fail(error, request: request, stage: .preflight, startedAt: startedAt, steps: steps)
        }

        startedAt = steps.now()
        let receipt: AccountRefreshReceipt
        do {
            receipt = try await steps.provision()
            try AccountRefreshPlanner.validateProvision(receipt, against: request, now: steps.now())
            await record(request, stage: .provision, status: .succeeded, reason: nil, startedAt: startedAt, steps: steps)
        } catch {
            return await fail(error, request: request, stage: .provision, startedAt: startedAt, steps: steps)
        }

        startedAt = steps.now()
        let handoff: AccountRefreshHandoff
        do {
            handoff = try await steps.importIdentity()
            try AccountRefreshPlanner.validateHandoff(handoff, against: request, receipt: receipt, now: steps.now())
            await record(request, stage: .importIdentity, status: .succeeded, reason: nil, startedAt: startedAt, steps: steps)
        } catch {
            return await fail(error, request: request, stage: .importIdentity, startedAt: startedAt, steps: steps)
        }

        startedAt = steps.now()
        let artifact: AccountRefreshSignedArtifact
        do {
            artifact = try await steps.sign(handoff)
            try AccountRefreshPlanner.validateSign(artifact, handoff: handoff)
            await record(request, stage: .sign, status: .succeeded, reason: nil, startedAt: startedAt, steps: steps)
        } catch {
            return await fail(error, request: request, stage: .sign, startedAt: startedAt, steps: steps)
        }

        startedAt = steps.now()
        let installation: AccountRefreshInstallation
        do {
            installation = try await steps.install(artifact)
            try AccountRefreshPlanner.validateInstallation(installation, artifact: artifact)
            await record(request, stage: .install, status: .succeeded, reason: nil, startedAt: startedAt, steps: steps)
        } catch {
            return await fail(error, request: request, stage: .install, startedAt: startedAt, steps: steps)
        }

        startedAt = steps.now()
        do {
            let verification = try await steps.verify(installation)
            try AccountRefreshPlanner.validateVerification(verification, request: request)
            let status: OperationOutcomeStatus
            let reason: String?
            if verification.isVerified {
                status = .succeeded
                reason = nil
            } else {
                status = .unconfirmed
                reason = "No exact device evidence was reported. Check the Home Screen before installing again."
            }
            await record(request, stage: .verify, status: status, reason: reason, startedAt: startedAt, steps: steps)
            return .completed(AccountRefreshResult(
                correlationID: request.correlationID,
                certificateUUID: handoff.certificateUUID,
                profileUUID: receipt.profileUUID,
                expiresAt: receipt.expiresAt,
                signedArtifactID: artifact.artifactID,
                verification: verification
            ))
        } catch {
            return await fail(error, request: request, stage: .verify, startedAt: startedAt, steps: steps)
        }
    }

    private func fail(
        _ error: Error,
        request: AccountRefreshRequest,
        stage: AccountRefreshStage,
        startedAt: Date,
        steps: Steps
    ) async -> Outcome {
        let mapped = map(error, stage: stage)
        await record(
            request, stage: stage,
            status: mapped == .cancelled ? .cancelled : .failed,
            reason: mapped.errorDescription,
            startedAt: startedAt, steps: steps
        )
        return .failed(mapped)
    }

    private func map(_ error: Error, stage: AccountRefreshStage) -> AccountRefreshError {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let refreshError = error as? AccountRefreshError { return refreshError }
        return .stageFailed(stage, OperationOutcomeSanitizer.reason(error.localizedDescription) ?? "unknown error")
    }

    private func record(
        _ request: AccountRefreshRequest,
        stage: AccountRefreshStage,
        status: OperationOutcomeStatus,
        reason: String?,
        startedAt: Date,
        steps: Steps
    ) async {
        await steps.record(OperationOutcomeRecord(
            correlationID: request.correlationID.uuidString,
            operation: Self.operation,
            stage: stage.rawValue,
            status: status,
            reason: OperationOutcomeSanitizer.reason(reason),
            startedAt: startedAt,
            finishedAt: steps.now()
        ))
    }
}

private extension AccountRefreshVerification {
    var isVerified: Bool {
        if case .confirmed = self { return true }
        return false
    }
}
