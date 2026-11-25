//
//  AccountRefreshPipeline.swift
//  VexSign
//
//  Production wiring for the manual account refresh. The two account stages stay
//  injected: they require approvals the user gives on the provisioning review,
//  and neither a Shortcut nor a background pass may supply them. Signing and
//  installing reuse the existing pipelines; verification uses the caller's probe,
//  which defaults to the one that refuses to guess.
//

import Foundation

@MainActor
struct AccountRefreshPipeline {
    let app: AppInfoPresentable
    let provision: @MainActor () async throws -> AccountRefreshReceipt
    let importIdentity: @MainActor () async throws -> AccountRefreshHandoff
    let record: OperationOutcomeRecording
    let probe: any InstalledAppProbing

    init(
        app: AppInfoPresentable,
        provision: @escaping @MainActor () async throws -> AccountRefreshReceipt,
        importIdentity: @escaping @MainActor () async throws -> AccountRefreshHandoff,
        record: @escaping OperationOutcomeRecording,
        probe: any InstalledAppProbing = UnavailableInstallationProbe()
    ) {
        self.app = app
        self.provision = provision
        self.importIdentity = importIdentity
        self.record = record
        self.probe = probe
    }

    func run(_ request: AccountRefreshRequest) async -> ManualAccountRefreshCoordinator.Outcome {
        let signed = SignedArtifactBox()
        let steps = ManualAccountRefreshCoordinator.Steps(
            provision: provision,
            importIdentity: importIdentity,
            sign: { handoff in
                // Pin the identity just imported. A saved profile that points at any
                // other certificate must not silently become the refresh identity.
                var options = SigningProfileStore.shared.profile(forBundleID: request.bundleIdentifier)?.options ?? Options.batchBase
                options.post_installAppAfterSigned = false
                SigningProfileStore.shared.capture(options: options, certificateUUID: handoff.certificateUUID, for: app)
                let result = await AutoSignManager.shared.sign(app)
                switch result {
                case .failure(let error):
                    throw error
                case .success(let output):
                    guard let artifactID = output.uuid, !artifactID.isEmpty else {
                        throw AccountRefreshError.appChanged
                    }
                    signed.app = output
                    return AccountRefreshSignedArtifact(
                        artifactID: artifactID,
                        certificateUUID: handoff.certificateUUID,
                        bundleIdentifier: request.bundleIdentifier
                    )
                }
            },
            install: { artifact in
                guard let ready = signed.app else { throw AccountRefreshError.appChanged }
                // Enqueue is a handoff, not an install result. Verification is a later
                // stage and uses device evidence only.
                InstallQueue.shared.enqueue(ready)
                return AccountRefreshInstallation(
                    artifactID: artifact.artifactID,
                    bundleIdentifier: artifact.bundleIdentifier,
                    submitted: true
                )
            },
            verify: { installation in
                guard let reading = probe.installedApp(for: installation.bundleIdentifier),
                      reading.isInstalled, !reading.isPlaceholder,
                      reading.bundleIdentifier == installation.bundleIdentifier else {
                    return .unconfirmed
                }
                return .confirmed(bundleIdentifier: reading.bundleIdentifier, installedVersion: reading.version)
            },
            record: record
        )
        return await ManualAccountRefreshCoordinator().run(request, steps: steps)
    }
}

/// The signed copy from the sign stage, kept behind a reference so the injected
/// steps can pass it to the install stage without relying on an unowned global.
@MainActor
private final class SignedArtifactBox {
    var app: Signed?
}
