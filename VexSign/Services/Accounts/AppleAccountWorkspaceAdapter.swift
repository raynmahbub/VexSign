import CryptoKit
import Foundation
import Combine
import NativeSigning

/// Reuses the account manager and its receipt/approval-backed package operations.
/// There is no second account backend, signing engine or renewal pipeline here.
@MainActor
final class AppleAccountWorkspaceAdapter: AppleAccountWorkspaceProviding {
    private let manager: NativeSigningManager
    private let repository: CoreDataWorkspaceRepository
    private var operations: [UUID: NativeAccountOperation] = [:]
    private struct PendingProfile {
        let receipt: AppleAccountProvisioningReceipt
        let request: AppleAccountProvisioningRequest
        let bundleIdentifier: String
        let identityID: UUID
        let profile: NativeAccountProfileResult
    }
    private var pendingProfiles: [UUID: PendingProfile] = [:]
    init(manager: NativeSigningManager, repository: CoreDataWorkspaceRepository) {
        self.manager = manager; self.repository = repository
    }
    func state() -> AppleAccountState {
        AppleAccountState(selectedSlot: manager.selectedSlot.rawValue, snapshot: manager.snapshot.map(Self.snapshot), isBackendReady: manager.isBackendReady,
            lastError: manager.lastError, freeAccountAppCount: manager.freeAccountAppCount,
            freeAccountInventoryAvailable: manager.freeAccountInventoryAvailable,
            renewalCandidates: manager.renewalCandidates.map {
                AppleAccountRenewalCandidate(id: $0.id, bundleIdentifier: $0.bundleIdentifier, expiresAt: $0.expiresAt)
            })
    }
    func changes() -> AsyncStream<AppleAccountState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(state())
            let subscription = manager.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    continuation.yield(self.state())
                }
            }
            let observation = StreamObservationCancellation(subscription)
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
    func selectSlot(_ number: Int) async throws {
        guard let slot = NativeSigning.NativeAccountSlot(rawValue: number) else { throw NativeAccountBackendError.invalidConfiguration }
        guard manager.selectedSlot != slot else { return }
        operations.removeAll(); pendingProfiles.removeAll()
        await manager.synchronizeProvider(slot: slot)
    }
    func revalidate() async throws -> AppleAccountOperation {
        let operation = try await manager.revalidate()
        operations = [operation.id: operation]
        return AppleAccountOperation(id: operation.id)
    }
    func synchronizeProvider() async { await manager.synchronizeProvider() }
    func refreshSnapshot() async { await manager.refreshSnapshot() }
    func refreshRenewalCandidates() async { await manager.refreshRenewalCandidates() }
    func authenticate(appleID: String, password: String, xcodeVersion: String) async throws -> AppleAccountOperation {
        let operation = try await manager.authenticate(appleID: appleID, password: password, xcodeVersion: xcodeVersion)
        if Task.isCancelled {
            await manager.cancelAuthentication(operationID: operation.id)
            throw CancellationError()
        }
        operations = [operation.id: operation]
        return AppleAccountOperation(id: operation.id)
    }
    func challenges(operationID: UUID) -> AsyncStream<AppleAccountChallenge> {
        guard let operation = operations[operationID] else { return AsyncStream { $0.finish() } }
        let events = manager.challenges(for: operation)
        return AsyncStream { continuation in
            let task = Task {
                for await challenge in events {
                    guard !Task.isCancelled else { break }
                    continuation.yield(AppleAccountChallenge(operationID: challenge.operationID,
                        id: challenge.id, isRetry: challenge.isRetry))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func submitTwoFactorCode(_ code: String, operationID: UUID, challengeID: UUID) async throws -> Bool {
        guard operations[operationID] != nil else { throw AppleAccountWorkspaceError.noActiveContext }
        return try await manager.submitTwoFactorCode(code, operationID: operationID, challengeID: challengeID)
    }
    func cancelAuthentication(operationID: UUID) async {
        operations.removeValue(forKey: operationID)
        await manager.cancelAuthentication(operationID: operationID)
    }
    func selectTeam(identifier: String, operationID: UUID) async throws {
        guard operations[operationID] != nil else { throw AppleAccountWorkspaceError.noActiveContext }
        try await manager.selectTeam(identifier: identifier, operationID: operationID)
        operations.removeValue(forKey: operationID)
    }
    func signOut() async throws {
        try await manager.signOut()
        operations.removeAll(); pendingProfiles.removeAll()
    }
    func listSigningIdentities() async -> [AppleAccountIdentity] {
        await manager.listSigningIdentities().map { AppleAccountIdentity(id: $0.id, teamIdentifier: $0.teamIdentifier) }
    }
    func checkCertificate(contextID: UUID, identityID: UUID) async throws -> AppleAccountCertificateCheck {
        try requireContext(contextID)
        // The UI's consent confirmation is translated to the manager's actual
        // short-lived, single-use grant. Never pass nil and pretend it authorized a check.
        let consent = try await manager.recordCertificateStatusConsent(contextID: contextID, identityID: identityID)
        try Task.checkCancellation()
        let result = try await manager.evaluateCertificateStatus(contextID: contextID, identityID: identityID, consent: consent)
        try Task.checkCancellation()
        try requireContext(contextID)
        return AppleAccountCertificateCheck(checkedAt: result.checkedAt)
    }
    /// Use the selected artifact, not a cached certificate expiry or a portal display row.
    private func renewalBaseline(for app: AppInfoPresentable, request: AppleAccountProvisioningRequest,
                                 bundleID: String, deviceID: String) throws -> (expiry: Date, digest: String)? {
        guard request.requireLaterProfile else { return nil }
        guard app.isSigned, let bundle = app.bundleURL,
              case .signedIn(let context) = state().snapshot?.phase, context.id == request.contextID else {
            throw AppleAccountWorkspaceError.incompatibleRenewalSource
        }
        let data = try CertificateInputReader.read(bundle.appendingPathComponent("embedded.mobileprovision"))
        let profile = try ProvisioningProfileParser.parse(data, allowingExpiredForDisplay: true)
        guard profile.CreationDate <= Date(), profile.TeamIdentifier == [context.team.identifier],
              profile.ProvisionedDevices?.contains(where: { $0.uppercased() == deviceID }) == true,
              profile.Entitlements?["get-task-allow"]?.value as? Bool == true,
              let appID = profile.Entitlements?["application-identifier"]?.value as? String,
              ProfileApplicationIdentifierMatcher.match(applicationIdentifier: appID, bundleIdentifier: bundleID).outcome.isAuthorized else {
            throw AppleAccountWorkspaceError.incompatibleRenewalSource
        }
        return (profile.ExpirationDate, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    // Catch only a refusal to issue a new approval. A failed write is never retried.
    private func resolveRegistration(contextID: UUID, subject: NativeRegistrationSubject, existingOnly: Bool) async throws -> NativeRegistrationResult {
        if existingOnly { return try await manager.reconcileRegistration(contextID: contextID, subject: subject) }
        let approval: NativeAccountRegistrationApproval
        do { approval = try await manager.recordRegistrationApproval(contextID: contextID, subject: subject) }
        catch NativeRegistrationError.reconciliationRequired {
            try Task.checkCancellation()
            return try await manager.reconcileRegistration(contextID: contextID, subject: subject)
        }
        try Task.checkCancellation()
        return try await manager.registerResource(contextID: contextID, subject: subject, approval: approval)
    }

    private func resolveProfile(contextID: UUID, target: NativeAccountProfileTarget) async throws -> NativeAccountProfileResult {
        let approval: NativeAccountProfileApproval
        do { approval = try await manager.recordProfileCreationApproval(contextID: contextID, target: target) }
        catch NativeProfileCreationError.reconciliationRequired {
            try Task.checkCancellation()
            return try await manager.reconcileProfile(contextID: contextID, target: target)
        }
        try Task.checkCancellation()
        return try await manager.createProvisioningProfile(contextID: contextID, target: target, approval: approval)
    }

    func provision(_ request: AppleAccountProvisioningRequest,
                   progress: @escaping @MainActor (AppleAccountProvisioningProgress) -> Void) async throws -> AppleAccountProvisioningReceipt {
        try requireContext(request.contextID)
        let app = try repository.storage.managedApp(matching: request.app)
        guard let bundleID = app.identifier, !bundleID.isEmpty else { throw WorkspaceAccessError.invalidReference }
        let contextID = request.contextID
        let deviceID = request.deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        try Task.checkCancellation()
        let baseline = try renewalBaseline(for: app, request: request, bundleID: bundleID, deviceID: deviceID)
        if request.approveRegeneration && baseline == nil { throw AppleAccountWorkspaceError.incompatibleRenewalSource }
        // Require a configured cryptographic verifier before quota-affecting work.
        try await manager.requireProfileOperations()
        progress(.init(stage: .preflight, fraction: 0.1))
        let preflight = try NativeAccountProvisioningRequest(deviceIdentifier: deviceID, bundleIdentifiers: [bundleID])
        _ = try await manager.provisioningPreflight(contextID: contextID, request: preflight)
        try Task.checkCancellation()
        progress(.init(stage: .identity, fraction: 0.25))
        let identityID: UUID
        if request.approveRegeneration {
            let existing = await manager.listSigningIdentities().filter { $0.phase == .certificateRecorded }
            guard existing.count == 1, let owned = existing.first else { throw AppleAccountWorkspaceError.incompatibleRenewalSource }
            identityID = owned.identityID
            try requireContext(contextID)
        } else {
            let identity = try await manager.prepareSigningIdentity(contextID: contextID)
            try Task.checkCancellation()
            switch identity.phase {
            case .prepared:
                progress(.init(stage: .certificateApproval, fraction: 0.4))
                let approval = try await manager.recordCertificateCreationApproval(contextID: contextID, identityID: identity.id)
                try Task.checkCancellation()
                _ = try await manager.createDevelopmentCertificate(contextID: contextID, identityID: identity.id, approval: approval)
            case .submissionUncertain:
                _ = try await manager.reconcileCertificate(contextID: contextID, identityID: identity.id)
            case .certificateRecorded: break
            }
            identityID = identity.id
        }
        try Task.checkCancellation()
        progress(.init(stage: .registration, fraction: 0.7))
        let device = try NativeRegistrationSubject(kind: .device, value: deviceID)
        let deviceRegistration = try await resolveRegistration(contextID: contextID, subject: device, existingOnly: request.approveRegeneration)
        try Task.checkCancellation()
        progress(.init(stage: .appRegistration, fraction: 0.8))
        let appID = try NativeRegistrationSubject(kind: .appID, value: bundleID)
        let appRegistration = try await resolveRegistration(contextID: contextID, subject: appID, existingOnly: request.approveRegeneration)
        try Task.checkCancellation()
        progress(.init(stage: .profile, fraction: 0.9))
        let target = try NativeAccountProfileTarget(identityID: identityID, bundleIdentifier: bundleID,
            deviceIdentifier: deviceID, appRegistration: appRegistration, deviceRegistration: deviceRegistration)
        let profile: NativeAccountProfileResult
        if request.approveRegeneration, let baseline {
            profile = try await manager.renewApprovedProfile(contextID: contextID, target: target, baselineDigest: baseline.digest)
        } else {
            profile = try await resolveProfile(contextID: contextID, target: target)
        }
        try Task.checkCancellation()
        try requireContext(contextID)
        let currentApp = try repository.storage.managedApp(matching: request.app)
        guard currentApp.identifier == bundleID, profile.expiresAt > Date() else { throw AppleAccountWorkspaceError.missingReceipt }
        if let baseline, profile.expiresAt <= baseline.expiry { throw AppleAccountWorkspaceError.expiryNotAdvanced }
        let receipt = AppleAccountProvisioningReceipt(id: UUID(), profileUUID: profile.profileUUID, expiresAt: profile.expiresAt)
        // Keep only current, unexpired metadata; no key or password is retained here.
        pendingProfiles = pendingProfiles.filter { $0.value.profile.expiresAt > Date() && $0.value.request.contextID == contextID }
        if pendingProfiles.count >= 16 { pendingProfiles.removeAll() }
        pendingProfiles[receipt.id] = PendingProfile(receipt: receipt, request: request,
            bundleIdentifier: bundleID, identityID: identityID, profile: profile)
        progress(.init(stage: .completed, fraction: 1))
        return receipt
    }
    func importCertificate(receiptID: UUID) async throws -> AppleAccountSigningHandoff {
        guard let pending = pendingProfiles[receiptID], pending.profile.expiresAt > Date() else {
            throw AppleAccountWorkspaceError.missingReceipt
        }
        try requireContext(pending.request.contextID)
        let app = try repository.storage.managedApp(matching: pending.request.app)
        guard app.identifier == pending.bundleIdentifier else { throw WorkspaceAccessError.mismatchedRecord }
        if let currentExpiry = try renewalBaseline(for: app, request: pending.request, bundleID: pending.bundleIdentifier,
            deviceID: pending.request.deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()),
           pending.profile.expiresAt <= currentExpiry.expiry { throw AppleAccountWorkspaceError.expiryNotAdvanced }
        let consent = try await manager.recordKeyExportConsent(contextID: pending.request.contextID, identityID: pending.identityID)
        try Task.checkCancellation()
        let certificateUUID = try await manager.exportToCertificateStore(contextID: pending.request.contextID, profile: pending.profile,
            identityID: pending.identityID, bundleIdentifier: pending.bundleIdentifier,
            deviceIdentifier: pending.request.deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), consent: consent)
        pendingProfiles.removeValue(forKey: receiptID)
        try Task.checkCancellation()
        try requireContext(pending.request.contextID)
        let current = try repository.storage.managedApp(matching: pending.request.app)
        guard current.identifier == pending.bundleIdentifier else { throw WorkspaceAccessError.mismatchedRecord }
        return AppleAccountSigningHandoff(app: pending.request.app, bundleIdentifier: pending.bundleIdentifier,
            certificateUUID: certificateUUID, profileUUID: pending.profile.profileUUID, expiresAt: pending.profile.expiresAt)
    }
    private func requireContext(_ id: UUID) throws {
        guard case .signedIn(let context) = manager.snapshot?.phase, context.id == id,
              context.expiresAt.map({ $0 > Date() }) ?? true else {
            throw AppleAccountWorkspaceError.noActiveContext
        }
    }
    private static func snapshot(_ value: NativeAccountSnapshot) -> AppleAccountSnapshot {
        let phase: AppleAccountPhase
        switch value.phase {
        case .signedOut: phase = .signedOut
        case .authenticating(let id): phase = .authenticating(id)
        case .awaitingTwoFactor(let id): phase = .awaitingTwoFactor(id)
        case .awaitingTeamSelection(let id, let teams, let expiry): phase = .awaitingTeamSelection(id, teams.map(team), expiresAt: expiry)
        case .signedIn(let context): phase = .signedIn(AppleAccountContext(id: context.id, team: team(context.team), expiresAt: context.expiresAt))
        case .expired(let expiry): phase = .expired(expiresAt: expiry)
        }
        return AppleAccountSnapshot(phase: phase, cleanupRequired: value.cleanupRequired)
    }
    private static func team(_ value: NativeAccountTeam) -> AppleAccountTeam {
        let membership: AppleAccountMembership
        switch value.membership {
        case .free: membership = .free
        case .paidVerified: membership = .paidVerified
        case .developerProgramUnverified: membership = .developerProgramUnverified
        }
        return AppleAccountTeam(identifier: value.identifier, membership: membership)
    }
}
