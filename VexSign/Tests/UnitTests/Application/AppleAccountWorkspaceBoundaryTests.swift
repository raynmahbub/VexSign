import Foundation
import XCTest
@testable import VexSign

@MainActor
final class AppleAccountWorkspaceBoundaryTests: XCTestCase {
    private final class Provider: AppleAccountWorkspaceProviding {
        var provisionCount = 0
        var checkCount = 0
        var imported: [UUID] = []
        var cancelled: [UUID] = []
        var started: XCTestExpectation?
        var pending: CheckedContinuation<AppleAccountProvisioningReceipt, Error>?
        func state() -> AppleAccountState { AppleAccountState() }
        func changes() -> AsyncStream<AppleAccountState> { AsyncStream { $0.finish() } }
        func synchronizeProvider() async {}
        func refreshSnapshot() async {}
        func refreshRenewalCandidates() async {}
        func authenticate(appleID: String, password: String, xcodeVersion: String) async throws -> AppleAccountOperation { AppleAccountOperation(id: UUID()) }
        func challenges(operationID: UUID) -> AsyncStream<AppleAccountChallenge> { AsyncStream { $0.finish() } }
        func submitTwoFactorCode(_ code: String, operationID: UUID, challengeID: UUID) async throws -> Bool { true }
        func cancelAuthentication(operationID: UUID) async { cancelled.append(operationID) }
        func selectTeam(identifier: String, operationID: UUID) async throws {}
        func signOut() async throws {}
        func listSigningIdentities() async -> [AppleAccountIdentity] { [] }
        func checkCertificate(contextID: UUID, identityID: UUID) async throws -> AppleAccountCertificateCheck {
            checkCount += 1; return AppleAccountCertificateCheck(checkedAt: Date())
        }
        func provision(_ request: AppleAccountProvisioningRequest, progress: @escaping @MainActor (AppleAccountProvisioningProgress) -> Void) async throws -> AppleAccountProvisioningReceipt {
            provisionCount += 1
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation; started?.fulfill()
            }
        }
        func importCertificate(receiptID: UUID) async throws { imported.append(receiptID) }
        func complete() {
            pending?.resume(returning: AppleAccountProvisioningReceipt(id: UUID(), profileUUID: UUID(), expiresAt: Date().addingTimeInterval(60)))
            pending = nil
        }
    }

    private func request() throws -> AppleAccountProvisioningRequest {
        AppleAccountProvisioningRequest(contextID: UUID(), app: try LibraryAppReference(app: FeatureBoundaryFixtures.app()), deviceIdentifier: "fixture-device")
    }

    func testEachApprovalRemainsIndependentlyRequiredBeforeQuotaWork() async throws {
        let provider = Provider()
        let useCase = AppleAccountWorkspaceUseCase(provider: provider)
        for approval in [AppleAccountProvisioningApproval(certificate: false, registration: true, profile: true),
                         AppleAccountProvisioningApproval(certificate: true, registration: false, profile: true),
                         AppleAccountProvisioningApproval(certificate: true, registration: true, profile: false)] {
            do { _ = try await useCase.provision(request(), approval: approval) { _ in }; XCTFail("Missing approval") }
            catch { XCTAssertEqual(error as? AppleAccountWorkspaceError, .approvalRequired) }
        }
        XCTAssertEqual(provider.provisionCount, 0)
    }

    func testAStatusCheckNeedsItsOwnConsent() async throws {
        let provider = Provider()
        let useCase = AppleAccountWorkspaceUseCase(provider: provider)
        do {
            _ = try await useCase.checkCertificate(contextID: UUID(), identityID: UUID(), consentGiven: false)
            XCTFail("Missing status consent")
        } catch { XCTAssertEqual(error as? AppleAccountWorkspaceError, .approvalRequired) }
        XCTAssertEqual(provider.checkCount, 0)
        _ = try await useCase.checkCertificate(contextID: UUID(), identityID: UUID(), consentGiven: true)
        XCTAssertEqual(provider.checkCount, 1)
    }

    func testProvisioningAndKeyExportCannotOverlap() async throws {
        let provider = Provider()
        let started = expectation(description: "provisioning owns workflow")
        provider.started = started
        let useCase = AppleAccountWorkspaceUseCase(provider: provider)
        let draft = try request()
        let operation = Task { @MainActor in
            try await useCase.provision(draft, approval: .init(certificate: true, registration: true, profile: true)) { _ in }
        }
        await fulfillment(of: [started], timeout: 2)
        let receipt = AppleAccountProvisioningReceipt(id: UUID(), profileUUID: UUID(), expiresAt: Date().addingTimeInterval(60))
        do { try await useCase.importCertificate(receipt, consentGiven: true); XCTFail("Concurrent key export") }
        catch { XCTAssertEqual(error as? ArchitectureDomainError, .duplicateOrBusyOperation) }
        XCTAssertTrue(provider.imported.isEmpty)
        provider.complete()
        _ = try await operation.value
        do { try await useCase.importCertificate(receipt, consentGiven: false); XCTFail("Provisioning approval is not key export consent") }
        catch { XCTAssertEqual(error as? AppleAccountWorkspaceError, .approvalRequired) }
        try await useCase.importCertificate(receipt, consentGiven: true)
        XCTAssertEqual(provider.imported, [receipt.id])
    }

    func testEmptyTeamChoiceCancelsTheSpecificAuthentication() async throws {
        let provider = Provider()
        let useCase = AppleAccountWorkspaceUseCase(provider: provider)
        let operation = UUID()
        try await useCase.selectTeam(identifier: "", operationID: operation)
        XCTAssertEqual(provider.cancelled, [operation])
    }

    func testCancellationBeforeStartNeverReachesProvisioningProvider() async throws {
        let provider = Provider()
        let useCase = AppleAccountWorkspaceUseCase(provider: provider)
        let draft = try request()
        let cancelled = await withTaskGroup(of: Bool.self) { group in
            group.cancelAll()
            group.addTask { @MainActor in
                do {
                    _ = try await useCase.provision(draft, approval: .init(certificate: true, registration: true, profile: true)) { _ in }
                    return false
                } catch { return error is CancellationError }
            }
            return await group.next() ?? false
        }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(provider.provisionCount, 0)
    }
}
