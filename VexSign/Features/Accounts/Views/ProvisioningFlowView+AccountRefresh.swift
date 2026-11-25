//
//  ProvisioningFlowView+AccountRefresh.swift
//  VexSign
//
//  The attended account refresh entry point. It builds the six-stage workflow
//  from the same approvals the provisioning review already collects, pins the
//  identity the account just returned, and records every stage through the
//  injected journal. It never runs from a background pass or a Shortcut.
//

import SwiftUI
import NimbleExtensions

extension ProvisioningFlowView {
    @MainActor
    func runAccountRefresh() async {
        guard refreshReview,
              let accountContext = self.accountContext,
              reviewedContextID == accountContext.id,
              let app = selectedApp else {
            errorMessage = .localized("Select the signed app and review this refresh again.")
            return
        }
        guard app.isSigned,
              let bundleIdentifier = app.identifier, !bundleIdentifier.isEmpty,
              let deviceUUID = app.uuid, !deviceUUID.isEmpty else {
            errorMessage = .localized("Account refresh needs a signed library copy with an app identifier.")
            return
        }
        guard !deviceIdentifier.isEmpty else {
            errorMessage = .localized("Choose the target device before starting the refresh.")
            return
        }
        guard let certificate = services.library.certificate(for: app),
              let certificateUUID = certificate.uuid, !certificateUUID.isEmpty,
              let profile = certificate.profile,
              let profileUUID = UUID(uuidString: profile.UUID),
              profile.ExpirationDate.timeIntervalSince1970.isFinite else {
            errorMessage = .localized("The signed copy has no readable certificate and profile to replace. Refresh cannot establish a baseline.")
            return
        }
        guard consent.approval.isComplete, consent.regeneration, consent.keyExport else {
            errorMessage = .localized("Approve provisioning, one regeneration and the one-time key export before starting.")
            return
        }

        let reference: LibraryAppReference
        do {
            reference = try LibraryAppReference(app: app)
        } catch {
            errorMessage = .localized("The signed library copy changed. Select it again and review the refresh.")
            return
        }

        let request = AccountRefreshRequest(
            correlationID: UUID(),
            app: reference,
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: accountContext.team.identifier,
            certificateUUID: certificateUUID,
            profileUUID: profileUUID,
            baselineExpiry: profile.ExpirationDate
        )

        let approval = consent.approval
        let outcomes = services.operationOutcomes
        var provisionedReceipt: AppleAccountProvisioningReceipt?
        let pipeline = AccountRefreshPipeline(
            app: app,
            provision: {
                guard self.contextID == accountContext.id,
                      self.reviewedContextID == accountContext.id else {
                    throw AccountRefreshError.cancelled
                }
                let portalRequest = AppleAccountProvisioningRequest(
                    contextID: accountContext.id,
                    app: reference,
                    deviceIdentifier: deviceIdentifier,
                    requireLaterProfile: true,
                    approveRegeneration: true
                )
                self.consent.regeneration = false // consumed even when Apple refuses the request
                let receipt = try await self.manager.provision(portalRequest, approval: approval) { progress in
                    guard self.contextID == accountContext.id,
                          self.reviewedContextID == accountContext.id else { return }
                    self.updateStage(progress.stage.title, progress.fraction)
                }
                provisionedReceipt = receipt
                return AccountRefreshBridging.receipt(from: receipt)
            },
            // The coordinator validates the handoff against the provision
            // receipt it just observed; this closure must match the injected
            // no-argument signature or Swift reports an arity error.
            importIdentity: {
                guard let receipt = provisionedReceipt else { throw AccountRefreshError.invalidInput }
                let handoff = try await self.manager.importCertificate(receipt, consentGiven: true)
                guard handoff.matches(app) else { throw AccountRefreshError.appChanged }
                return AccountRefreshBridging.handoff(from: handoff)
            },
            record: { outcome in
                await outcomes.record(outcome)
            }
        )

        isProvisioning = true
        provisioningProgress = 0
        provisioningStage = .localized("Refreshing…")
        errorMessage = nil
        refreshResult = nil
        defer { isProvisioning = false }

        let outcome = await pipeline.run(request)
        guard !Task.isCancelled, self.contextID == accountContext.id,
              self.reviewedContextID == accountContext.id else { return }
        switch outcome {
        case .completed(let result):
            refreshResult = result
            consent.keyExport = false
            step = .complete
        case .failed(let error):
            errorMessage = OperationOutcomeSanitizer.reason(error.localizedDescription)
                ?? .localized("The account refresh stopped. No later stage started.")
            step = .review
        }
    }

    /// The signed-in account, derived from the same snapshot the review screens use.
    private var accountContext: AppleAccountContext? {
        guard case .signedIn(let context) = manager.snapshot?.phase else { return nil }
        return context
    }
}
