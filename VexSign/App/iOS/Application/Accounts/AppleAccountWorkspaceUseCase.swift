import Foundation

@MainActor
final class AppleAccountWorkspaceUseCase {
    private let provider: AppleAccountWorkspaceProviding
    private var provisioning = false
    init(provider: AppleAccountWorkspaceProviding) { self.provider = provider }
    func state() -> AppleAccountState { provider.state() }
    func changes() -> AsyncStream<AppleAccountState> { provider.changes() }
    func selectSlot(_ slot: Int) async throws {
        guard !provisioning else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        try await provider.selectSlot(slot)
    }
    func revalidate() async throws -> AppleAccountOperation {
        try Task.checkCancellation()
        return try await provider.revalidate()
    }
    func synchronizeProvider() async { await provider.synchronizeProvider() }
    func refreshSnapshot() async { await provider.refreshSnapshot() }
    func refreshRenewalCandidates() async { await provider.refreshRenewalCandidates() }
    func authenticate(appleID: String, password: String, xcodeVersion: String) async throws -> AppleAccountOperation {
        try Task.checkCancellation()
        return try await provider.authenticate(appleID: appleID, password: password, xcodeVersion: xcodeVersion)
    }
    func challenges(for operation: AppleAccountOperation) -> AsyncStream<AppleAccountChallenge> {
        provider.challenges(operationID: operation.id)
    }
    func submitTwoFactorCode(_ code: String, operationID: UUID, challengeID: UUID) async throws -> Bool {
        try Task.checkCancellation()
        return try await provider.submitTwoFactorCode(code, operationID: operationID, challengeID: challengeID)
    }
    func cancelAuthentication(operationID: UUID) async { await provider.cancelAuthentication(operationID: operationID) }
    func selectTeam(identifier: String, operationID: UUID) async throws {
        if identifier.isEmpty { await provider.cancelAuthentication(operationID: operationID); return }
        try Task.checkCancellation()
        try await provider.selectTeam(identifier: identifier, operationID: operationID)
    }
    func signOut() async throws { try await provider.signOut() }
    func listSigningIdentities() async -> [AppleAccountIdentity] { await provider.listSigningIdentities() }
    func checkCertificate(contextID: UUID, identityID: UUID, consentGiven: Bool) async throws -> AppleAccountCertificateCheck {
        guard consentGiven else { throw AppleAccountWorkspaceError.approvalRequired }
        try Task.checkCancellation()
        return try await provider.checkCertificate(contextID: contextID, identityID: identityID)
    }
    func provision(_ request: AppleAccountProvisioningRequest, approval: AppleAccountProvisioningApproval,
                   progress: @escaping @MainActor (AppleAccountProvisioningProgress) -> Void) async throws -> AppleAccountProvisioningReceipt {
        guard approval.isComplete else { throw AppleAccountWorkspaceError.approvalRequired }
        guard !provisioning else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        provisioning = true
        defer { provisioning = false }
        try Task.checkCancellation()
        return try await provider.provision(request, progress: progress)
    }
    func importCertificate(_ receipt: AppleAccountProvisioningReceipt, consentGiven: Bool) async throws -> AppleAccountSigningHandoff {
        guard consentGiven else { throw AppleAccountWorkspaceError.approvalRequired }
        guard !provisioning else { throw ArchitectureDomainError.duplicateOrBusyOperation }
        provisioning = true
        defer { provisioning = false }
        try Task.checkCancellation()
        let handoff = try await provider.importCertificate(receiptID: receipt.id)
        try Task.checkCancellation()
        guard handoff.profileUUID == receipt.profileUUID, handoff.expiresAt == receipt.expiresAt,
              handoff.expiresAt > Date(), UUID(uuidString: handoff.certificateUUID) != nil else {
            throw AppleAccountWorkspaceError.missingReceipt
        }
        // Only a later user action may open review; nothing starts signing here.
        return handoff
    }
}
