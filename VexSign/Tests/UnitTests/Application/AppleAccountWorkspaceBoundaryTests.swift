import Foundation
import XCTest
@testable import VexSign

@MainActor
final class AppleAccountWorkspaceBoundaryTests: XCTestCase {
    private final class Provider: AppleAccountWorkspaceProviding {
        var provisionCount = 0
        var checkCount = 0
        var imported: [UUID] = []
        var handoff: AppleAccountSigningHandoff?
        var cancelled: [UUID] = []
        var started: XCTestExpectation?
        var pending: CheckedContinuation<AppleAccountProvisioningReceipt, Error>?
        func state() -> AppleAccountState { AppleAccountState() }
        func changes() -> AsyncStream<AppleAccountState> { AsyncStream { $0.finish() } }
        var selectedSlots: [Int] = []
        var resumes = 0
        func selectSlot(_ slot: Int) async throws { selectedSlots.append(slot) }
        func revalidate() async throws -> AppleAccountOperation { resumes += 1; return AppleAccountOperation(id: UUID()) }
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
        func importCertificate(receiptID: UUID) async throws -> AppleAccountSigningHandoff {
            imported.append(receiptID)
            guard let handoff else { throw AppleAccountWorkspaceError.missingReceipt }
            return handoff
        }
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

    func testSlotSelectionDoesNotImplicitlyResume() async throws {
        let provider = Provider(), slot = 4
        let useCase = AppleAccountWorkspaceUseCase(provider: provider)
        try await useCase.selectSlot(slot)
        XCTAssertEqual(provider.selectedSlots, [slot])
        XCTAssertEqual(provider.resumes, 0)
        _ = try await useCase.revalidate()
        XCTAssertEqual(provider.resumes, 1)
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
        do { _ = try await useCase.importCertificate(receipt, consentGiven: true); XCTFail("Concurrent key export") }
        catch { XCTAssertEqual(error as? ArchitectureDomainError, .duplicateOrBusyOperation) }
        XCTAssertTrue(provider.imported.isEmpty)
        do { try await useCase.selectSlot(2); XCTFail("Concurrent slot switch") }
        catch { XCTAssertEqual(error as? ArchitectureDomainError, .duplicateOrBusyOperation) }
        XCTAssertTrue(provider.selectedSlots.isEmpty)
        provider.complete()
        _ = try await operation.value
        do { _ = try await useCase.importCertificate(receipt, consentGiven: false); XCTFail("Provisioning approval is not key export consent") }
        catch { XCTAssertEqual(error as? AppleAccountWorkspaceError, .approvalRequired) }
        let app = FeatureBoundaryFixtures.app()
        let handoff = AppleAccountSigningHandoff(app: try LibraryAppReference(app: app),
            bundleIdentifier: app.identifier!, certificateUUID: UUID().uuidString,
            profileUUID: receipt.profileUUID, expiresAt: receipt.expiresAt)
        provider.handoff = handoff
        let imported = try await useCase.importCertificate(receipt, consentGiven: true)
        XCTAssertEqual(imported, handoff)
        XCTAssertEqual(provider.imported, [receipt.id])
    }

    func testImportResultMustMatchTheReviewedProfileAndExpiry() async throws {
        let provider = Provider()
        let useCase = AppleAccountWorkspaceUseCase(provider: provider)
        let receipt = AppleAccountProvisioningReceipt(id: UUID(), profileUUID: UUID(), expiresAt: Date().addingTimeInterval(300))
        let app = FeatureBoundaryFixtures.app()
        for (uuid, expiry, certificateUUID) in [
            (UUID(), receipt.expiresAt, UUID().uuidString),
            (receipt.profileUUID, receipt.expiresAt.addingTimeInterval(1), UUID().uuidString),
            (receipt.profileUUID, receipt.expiresAt, "not-a-certificate-uuid")
        ] {
            provider.handoff = AppleAccountSigningHandoff(app: try LibraryAppReference(app: app),
                bundleIdentifier: app.identifier!, certificateUUID: certificateUUID,
                profileUUID: uuid, expiresAt: expiry)
            do {
                _ = try await useCase.importCertificate(receipt, consentGiven: true)
                XCTFail("A substituted import result cannot open signing review")
            } catch { XCTAssertEqual(error as? AppleAccountWorkspaceError, .missingReceipt) }
        }
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
