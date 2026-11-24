import Foundation
import Combine

@MainActor
final class AppleAccountWorkspaceModel: ObservableObject {
    @Published private(set) var state: AppleAccountState
    private let useCase: AppleAccountWorkspaceUseCase
    private var observation: Task<Void, Never>?
    init(useCase: AppleAccountWorkspaceUseCase) {
        self.useCase = useCase; state = useCase.state()
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await state in changes {
                guard !Task.isCancelled, let self else { break }
                self.state = state
            }
        }
    }
    deinit { observation?.cancel() }
    var snapshot: AppleAccountSnapshot? { state.snapshot }
    var isBackendReady: Bool { state.isBackendReady }
    var lastError: String? { state.lastError }
    var freeAccountAppCount: Int { state.freeAccountAppCount }
    var freeAccountInventoryAvailable: Bool { state.freeAccountInventoryAvailable }
    var renewalCandidates: [AppleAccountRenewalCandidate] { state.renewalCandidates }
    func selectSlot(_ slot: Int) async throws {
        defer { state = useCase.state() }
        try await useCase.selectSlot(slot)
    }
    func revalidate() async throws -> AppleAccountOperation {
        defer { state = useCase.state() }
        return try await useCase.revalidate()
    }
    func synchronizeProvider() async { await useCase.synchronizeProvider(); state = useCase.state() }
    func refreshSnapshot() async { await useCase.refreshSnapshot(); state = useCase.state() }
    func refreshRenewalCandidates() async { await useCase.refreshRenewalCandidates(); state = useCase.state() }
    func authenticate(appleID: String, password: String, xcodeVersion: String) async throws -> AppleAccountOperation {
        defer { state = useCase.state() }
        return try await useCase.authenticate(appleID: appleID, password: password, xcodeVersion: xcodeVersion)
    }
    func challenges(for operation: AppleAccountOperation) -> AsyncStream<AppleAccountChallenge> { useCase.challenges(for: operation) }
    func submitTwoFactorCode(_ code: String, operationID: UUID, challengeID: UUID) async throws -> Bool {
        defer { state = useCase.state() }
        return try await useCase.submitTwoFactorCode(code, operationID: operationID, challengeID: challengeID)
    }
    func cancelAuthentication(operationID: UUID) async { await useCase.cancelAuthentication(operationID: operationID); state = useCase.state() }
    func selectTeam(identifier: String, operationID: UUID) async throws {
        defer { state = useCase.state() }
        try await useCase.selectTeam(identifier: identifier, operationID: operationID)
    }
    func signOut() async throws {
        defer { state = useCase.state() }
        try await useCase.signOut()
    }
    func listSigningIdentities() async -> [AppleAccountIdentity] { await useCase.listSigningIdentities() }
    func checkCertificate(contextID: UUID, identityID: UUID, consentGiven: Bool) async throws -> AppleAccountCertificateCheck {
        try await useCase.checkCertificate(contextID: contextID, identityID: identityID, consentGiven: consentGiven)
    }
    func provision(_ request: AppleAccountProvisioningRequest, approval: AppleAccountProvisioningApproval,
                   progress: @escaping @MainActor (AppleAccountProvisioningProgress) -> Void) async throws -> AppleAccountProvisioningReceipt {
        try await useCase.provision(request, approval: approval, progress: progress)
    }
    func importCertificate(_ receipt: AppleAccountProvisioningReceipt, consentGiven: Bool) async throws -> AppleAccountSigningHandoff {
        try await useCase.importCertificate(receipt, consentGiven: consentGiven)
    }
}
