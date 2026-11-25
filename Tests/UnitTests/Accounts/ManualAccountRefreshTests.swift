import XCTest
@testable import VexSign

@MainActor
private final class OutcomeBox {
    var records: [OperationOutcomeRecord] = []
}

@MainActor
final class ManualAccountRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func request() -> AccountRefreshRequest {
        AccountRefreshRequest(
            correlationID: UUID(),
            app: LibraryAppReference(recordID: "record", uuid: "app-uuid", isSigned: true),
            deviceIdentifier: "DEVICE-1",
            bundleIdentifier: "com.example.app",
            teamIdentifier: "ABCDEFGHIJ",
            certificateUUID: "certificate-one",
            profileUUID: UUID(),
            baselineExpiry: now.addingTimeInterval(86_400)
        )
    }

    private func handoff(for request: AccountRefreshRequest) -> AccountRefreshHandoff {
        AccountRefreshHandoff(
            certificateUUID: request.certificateUUID,
            profileUUID: request.profileUUID,
            bundleIdentifier: request.bundleIdentifier,
            expiresAt: request.baselineExpiry.addingTimeInterval(86_400)
        )
    }

    private func steps(
        for request: AccountRefreshRequest,
        outcomes: OutcomeBox,
        verification: AccountRefreshVerification = .confirmed(bundleIdentifier: "com.example.app", installedVersion: "2.0"),
        handoffOverride: AccountRefreshHandoff? = nil
    ) -> ManualAccountRefreshCoordinator.Steps {
        ManualAccountRefreshCoordinator.Steps(
            now: { [now = self.now] in now },
            provision: {
                AccountRefreshReceipt(
                    profileUUID: request.profileUUID,
                    expiresAt: request.baselineExpiry.addingTimeInterval(86_400)
                )
            },
            importIdentity: { handoffOverride ?? handoff(for: request) },
            sign: { handoff in
                AccountRefreshSignedArtifact(
                    artifactID: "signed-copy",
                    certificateUUID: handoff.certificateUUID,
                    bundleIdentifier: handoff.bundleIdentifier
                )
            },
            install: { artifact in
                AccountRefreshInstallation(
                    artifactID: artifact.artifactID,
                    bundleIdentifier: artifact.bundleIdentifier,
                    submitted: true
                )
            },
            verify: { _ in verification },
            record: { outcomes.records.append($0) }
        )
    }

    func testCompleteRefreshRequiresEveryStageInOrder() async {
        let request = request()
        let outcomes = OutcomeBox()
        let result = await ManualAccountRefreshCoordinator().run(
            request,
            steps: steps(for: request, outcomes: outcomes)
        )
        guard case .completed(let value) = result else {
            return XCTFail("A consistent refresh should complete")
        }
        XCTAssertTrue(value.isVerified)
        XCTAssertEqual(value.signedArtifactID, "signed-copy")
        XCTAssertEqual(value.certificateUUID, request.certificateUUID)
        XCTAssertEqual(outcomes.records.map(\.stage), AccountRefreshStage.allCases.map(\.rawValue))
        XCTAssertTrue(outcomes.records.allSatisfy { $0.status == .succeeded })
        XCTAssertTrue(outcomes.records.allSatisfy { $0.correlationID == request.correlationID.uuidString })
    }

    func testChangedIdentityStopsBeforeSigningAndRecordsTheStage() async {
        let request = request()
        let outcomes = OutcomeBox()
        var changed = handoff(for: request)
        changed.certificateUUID = "certificate-two"
        let signed = Flag()
        let installed = Flag()
        var steps = steps(for: request, outcomes: outcomes, handoffOverride: changed)
        steps.sign = { _ in
            signed.value = true
            throw AccountRefreshError.appChanged
        }
        steps.install = { _ in
            installed.value = true
            throw AccountRefreshError.appChanged
        }
        let result = await ManualAccountRefreshCoordinator().run(request, steps: steps)
        guard case .failed(let error) = result else {
            return XCTFail("A different identity must end the refresh")
        }
        XCTAssertEqual(error, .identityChanged(expected: request.certificateUUID, actual: "certificate-two"))
        XCTAssertFalse(signed.value)
        XCTAssertFalse(installed.value)
        XCTAssertEqual(outcomes.records.last?.stage, AccountRefreshStage.importIdentity.rawValue)
        XCTAssertEqual(outcomes.records.last?.status, .failed)
    }

    func testProfileThatDoesNotAdvanceIsRejectedBeforeImport() async {
        let request = request()
        let outcomes = OutcomeBox()
        var steps = steps(for: request, outcomes: outcomes)
        steps.provision = {
            AccountRefreshReceipt(
                profileUUID: request.profileUUID,
                expiresAt: request.baselineExpiry
            )
        }
        let imported = Flag()
        steps.importIdentity = { _ in
            imported.value = true
            throw AccountRefreshError.appChanged
        }
        let result = await ManualAccountRefreshCoordinator().run(request, steps: steps)
        XCTAssertEqual(result, .failed(.expiryNotAdvanced))
        XCTAssertFalse(imported.value)
        XCTAssertEqual(outcomes.records.last?.stage, AccountRefreshStage.provision.rawValue)
    }

    func testUnverifiedInstallIsRecordedAsUnconfirmedNotSuccess() async {
        let request = request()
        let outcomes = OutcomeBox()
        let result = await ManualAccountRefreshCoordinator().run(
            request,
            steps: steps(for: request, outcomes: outcomes, verification: .unconfirmed)
        )
        guard case .completed(let value) = result else {
            return XCTFail("The flow can finish without a device reading")
        }
        XCTAssertFalse(value.isVerified)
        XCTAssertEqual(outcomes.records.last?.status, .unconfirmed)
    }

    func testCancellationRecordsCancelledAndRunsNothingLater() async {
        let request = request()
        let outcomes = OutcomeBox()
        var steps = steps(for: request, outcomes: outcomes)
        steps.provision = { throw CancellationError() }
        let signed = Flag()
        steps.sign = { _ in
            signed.value = true
            throw AccountRefreshError.appChanged
        }
        let result = await ManualAccountRefreshCoordinator().run(request, steps: steps)
        XCTAssertEqual(result, .failed(.cancelled))
        XCTAssertFalse(signed.value)
        XCTAssertEqual(outcomes.records.last?.status, .cancelled)
    }

    func testSanitizerRemovesPrivateDetailsFromRecordedReasons() {
        let reason = OperationOutcomeSanitizer.reason(
            "Sign in as person@example.com from /var/mobile/Containers/Data id 01234567-89ab-cdef-0123-456789abcdef password=hunter2\nfailed"
        )
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason?.contains("person@example.com") == true)
        XCTAssertFalse(reason?.contains("hunter2") == true)
        XCTAssertFalse(reason?.contains("01234567-89ab-cdef-0123-456789abcdef") == true)
        XCTAssertFalse(reason?.contains("\n") == true)
    }
}

@MainActor
private final class Flag {
    var value = false
}
