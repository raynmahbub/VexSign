import Foundation
import XCTest
@testable import VexSign

@MainActor
final class DirectInstallWorkspaceBoundaryTests: XCTestCase {
    private enum FixtureFailure: Error { case unavailable }

    private struct Policy: SecurityPolicyValidating {
        func validatePackageDownloadURL(_ url: URL) throws {
            guard url.scheme == "https" else { throw ArchitectureDomainError.invalidURL(url.absoluteString) }
        }
        func validateFirmwareDownloadURL(_ url: URL) throws {}
        func validateRepositoryURL(_ url: URL) throws {}
        func isAllowedCertificateCallbackTemplate(_ template: String) -> Bool { false }
        func isAllowedPackageExtension(_ ext: String) -> Bool { ext == "ipa" }
        func isAllowedTweakExtension(_ ext: String) -> Bool { false }
    }

    @MainActor
    private final class Transfers: SecureTransferProviding {
        var packages: [URL] = []
        func downloadValidatedPackage(from url: URL, workLabel: String, maximumBytes: Int64) async throws -> URL {
            packages.append(url)
            return URL(fileURLWithPath: "/fixture/package.ipa")
        }
        func downloadValidatedFirmware(from url: URL, to destination: URL) async throws -> URL { throw FixtureFailure.unavailable }
        func fetchFirmwareDevices() async throws -> [FirmwareDeviceRecord] { [] }
        func fetchFirmwareBuilds(deviceIdentifier: String) async throws -> [FirmwareBuildRecord] { [] }
        nonisolated func currentHardwareModelIdentifier() -> String? { nil }
    }

    private final class Installation: DirectInstallationProviding {
        var pipelineIsGuest = false
        var packageIsGuest = false
        var routingError: Error?
        var warns = true
        var suspendsImport = false
        var importStarted: XCTestExpectation?
        var pendingImport: CheckedContinuation<ImportedPackageHandle, Error>?
        var imported: [ImportedPackageHandle] = []
        var released: [ImportedPackageHandle] = []
        var accepted: [ImportedPackageHandle] = []
        var submitted: [(ImportedPackageHandle, Bool)] = []
        var queued: [URL] = []
        var onRelease: (() -> Void)?
        var leases = 0
        weak var activeLease: NSObject?

        func currentPipelineIsContainerized() throws -> Bool { pipelineIsGuest }
        func isContainerized(_ package: ImportedPackageHandle) throws -> Bool {
            if let routingError { throw routingError }
            return packageIsGuest
        }
        func enqueueDownload(_ url: URL, name: String) { queued.append(url) }
        func acquireTemporaryWork() throws -> AnyObject {
            let lease = NSObject()
            activeLease = lease
            leases += 1
            return lease
        }
        func importPackage(_ url: URL) async throws -> ImportedPackageHandle {
            let handle: ImportedPackageHandle
            if suspendsImport {
                handle = try await withCheckedThrowingContinuation { continuation in
                    pendingImport = continuation
                    importStarted?.fulfill()
                }
            } else {
                handle = ImportedPackageHandle()
            }
            // This fake models a registered artifact that survives retirement.
            imported.append(handle)
            return handle
        }
        func completeImport(_ handle: ImportedPackageHandle = ImportedPackageHandle()) {
            pendingImport?.resume(returning: handle)
            pendingImport = nil
        }
        func submitInstallation(_ package: ImportedPackageHandle, allowingIssues: Bool) throws {
            submitted.append((package, allowingIssues))
            if warns && !allowingIssues { throw DirectInstallationRequestError.verificationFailed(["Fixture warning"]) }
            accepted.append(package)
        }
        func releaseImportedPackage(_ package: ImportedPackageHandle) {
            released.append(package)
            onRelease?()
        }
    }

    private final class Platform: PlatformSystemAdapting {
        var confirmations: [() -> Void] = []
        var successes: [(message: String, image: String)] = []
        var errors: [String] = []
        var onPrompt: (() -> Void)?
        func openExternalURL(_ url: URL) {}
        func pasteboardString() -> String? { nil }
        func dismissKeyboard() {}
        func restartOrSuspendApp() {}
        func shareItems(_ items: [Any]) {}
        func notifySuccess(_ message: String, systemImage: String) { successes.append((message, systemImage)) }
        func notifyInfo(_ message: String, systemImage: String) {}
        func notifyError(_ message: String, sticky: Bool) { errors.append(message) }
        func presentDestructiveConfirmation(title: String, message: String, onConfirm: @escaping () -> Void) {}
        func presentYesNoAlert(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void) {
            confirmations.append(onConfirm)
            onPrompt?()
        }
        func presentErrorWithCopy(title: String, message: String) { errors.append(message) }
        func triggerHapticFeedback(success: Bool) {}
    }

    @MainActor
    private struct Fixture {
        let transfers: Transfers
        let installation: Installation
        let platform: Platform
        let useCase: DirectPackageInstallUseCase
        init() {
            transfers = Transfers()
            installation = Installation()
            platform = Platform()
            useCase = DirectPackageInstallUseCase(securityPolicy: Policy(), transferService: transfers,
                maximumPackageBytes: 1024, installation: installation)
        }
        func model() -> DirectInstallViewModel {
            DirectInstallViewModel(initialURL: "https://example.com/fixture.ipa", initialMode: .installWithoutSigning,
                useCase: useCase, platform: platform)
        }
        func execute(onStatus: (String) -> Void = { _ in }) async throws -> DirectInstallResult {
            try await useCase.execute(urlString: "https://example.com/fixture.ipa", mode: .installWithoutSigning, onStatus: onStatus)
        }
    }

    func testConcurrentExecuteCannotRetireTheFirstWorkerOrReleaseItsLease() async throws {
        let fixture = Fixture()
        fixture.installation.suspendsImport = true
        let started = expectation(description: "first import is suspended")
        fixture.installation.importStarted = started
        let first = Task { @MainActor in try await fixture.execute() }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await fixture.execute(); XCTFail("A second call must not replace the admitted import") }
        catch { XCTAssertEqual(error as? ArchitectureDomainError, .duplicateOrBusyOperation) }
        XCTAssertThrowsError(try fixture.useCase.confirmPendingInstall()) {
            XCTAssertEqual($0 as? ArchitectureDomainError, .duplicateOrBusyOperation)
        }
        XCTAssertEqual(fixture.installation.leases, 1)
        XCTAssertNotNil(fixture.installation.activeLease)
        XCTAssertTrue(fixture.installation.released.isEmpty)
        fixture.installation.completeImport()
        let result = try await first.value
        XCTAssertEqual(result, .needsIssueConfirmation(["Fixture warning"]))
        XCTAssertNil(fixture.installation.activeLease)
        XCTAssertEqual(try fixture.useCase.confirmPendingInstall(), .submittedForInstallation)
        XCTAssertEqual(fixture.installation.released, fixture.installation.imported)
    }

    func testRetiredImportKeepsAdmissionAndLeaseUntilItsWorkerReturns() async throws {
        let fixture = Fixture()
        fixture.installation.suspendsImport = true
        fixture.installation.warns = false
        let started = expectation(description: "import suspended")
        fixture.installation.importStarted = started
        let first = Task { @MainActor in try await fixture.execute() }
        await fulfillment(of: [started], timeout: 2)
        fixture.useCase.cancel()
        fixture.useCase.cancel()
        XCTAssertNotNil(fixture.installation.activeLease)
        do { _ = try await fixture.execute(); XCTFail("Retirement must not admit another worker before the first returns") }
        catch { XCTAssertEqual(error as? ArchitectureDomainError, .duplicateOrBusyOperation) }
        let committed = ImportedPackageHandle()
        fixture.installation.completeImport(committed)
        do { _ = try await first.value; XCTFail("Retired intent must not submit installation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.installation.imported, [committed])
        XCTAssertEqual(fixture.installation.released, [committed])
        XCTAssertTrue(fixture.installation.submitted.isEmpty)
        XCTAssertNil(fixture.installation.activeLease)
        // Once the original reader finishes, an explicit new attempt can run.
        fixture.installation.suspendsImport = false
        let retry = try await fixture.execute()
        XCTAssertEqual(retry, .submittedForInstallation)
    }

    func testTaskCancellationAfterRegistrationOnlyReleasesTheHandle() async throws {
        let fixture = Fixture()
        fixture.installation.suspendsImport = true
        let started = expectation(description: "import suspended")
        fixture.installation.importStarted = started
        let operation = Task { @MainActor in try await fixture.execute() }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        let committed = ImportedPackageHandle()
        fixture.installation.completeImport(committed)
        do { _ = try await operation.value; XCTFail("Cancelled import must not submit installation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.installation.imported, [committed])
        XCTAssertEqual(fixture.installation.released, [committed])
        XCTAssertTrue(fixture.installation.submitted.isEmpty)
        XCTAssertNil(fixture.installation.activeLease)
    }

    func testCancelledNewCallDoesNotDiscardAnExistingIssueConfirmation() async throws {
        let fixture = Fixture()
        let pending = try await fixture.execute()
        XCTAssertEqual(pending, .needsIssueConfirmation(["Fixture warning"]))
        let cancelled = Task { @MainActor in try await fixture.execute() }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation must be checked before pending state is changed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.installation.imported.count, 1)
        XCTAssertTrue(fixture.installation.released.isEmpty)
        XCTAssertEqual(try fixture.useCase.confirmPendingInstall(), .submittedForInstallation)
        XCTAssertEqual(fixture.installation.accepted, fixture.installation.imported)
    }

    func testCancelDiscardsOnlyThePendingHandleAndIsIdempotent() async throws {
        let fixture = Fixture()
        _ = try await fixture.execute()
        let committed = try XCTUnwrap(fixture.installation.imported.first)
        fixture.useCase.cancel()
        fixture.useCase.cancel()
        XCTAssertEqual(fixture.installation.released, [committed])
        XCTAssertEqual(fixture.installation.imported, [committed])
        XCTAssertThrowsError(try fixture.useCase.confirmPendingInstall())
        XCTAssertTrue(fixture.installation.accepted.isEmpty)
    }

    func testReentrantStatusRetirementCannotReachTheNextOwner() async {
        for cancelledStatus in 1...3 {
            let fixture = Fixture()
            fixture.installation.warns = false
            var statuses = 0
            do {
                _ = try await fixture.execute { _ in
                    statuses += 1
                    if statuses == cancelledStatus { fixture.useCase.cancel() }
                }
                XCTFail("A status callback retired this intent")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(fixture.installation.submitted.isEmpty)
            XCTAssertEqual(fixture.transfers.packages.count, cancelledStatus == 1 ? 0 : 1)
            XCTAssertEqual(fixture.installation.imported.count, cancelledStatus == 3 ? 1 : 0)
            XCTAssertEqual(fixture.installation.released, fixture.installation.imported)
            XCTAssertNil(fixture.installation.activeLease)
        }
    }

    func testAcceptedQueueAndInstallationHandoffsSurviveRetirement() async throws {
        let fixture = Fixture()
        let url = URL(string: "https://example.com/queued.ipa")!
        let queued = try await fixture.useCase.execute(urlString: url.absoluteString, mode: .signAndInstall, onStatus: { _ in })
        XCTAssertEqual(queued, .queuedForDownloadAndSign)
        fixture.useCase.cancel()
        XCTAssertEqual(fixture.installation.queued, [url])
        XCTAssertTrue(fixture.transfers.packages.isEmpty)
        fixture.installation.warns = false
        let submitted = try await fixture.execute()
        XCTAssertEqual(submitted, .submittedForInstallation)
        fixture.useCase.cancel()
        XCTAssertEqual(fixture.installation.accepted, fixture.installation.imported)
        XCTAssertEqual(fixture.installation.accepted.count, 1)
        XCTAssertEqual(fixture.installation.released, fixture.installation.imported)
    }

    func testUnknownRoutingRefusesHandoffAndReleasesTheImportedHandle() async {
        let fixture = Fixture()
        fixture.installation.routingError = FixtureFailure.unavailable
        do { _ = try await fixture.execute(); XCTFail("Unknown routing is not permission for a fallback") }
        catch { XCTAssertTrue(error is FixtureFailure) }
        XCTAssertEqual(fixture.installation.released, fixture.installation.imported)
        XCTAssertEqual(fixture.installation.imported.count, 1)
        XCTAssertTrue(fixture.installation.queued.isEmpty)
        XCTAssertTrue(fixture.installation.submitted.isEmpty)
    }

    func testHiddenModelCannotStartWork() {
        let fixture = Fixture()
        let model = fixture.model()
        model.startInstall { XCTFail("A hidden screen must not close a different presentation") }
        model.appear()
        model.disappear()
        model.startInstall { XCTFail("A dismissed screen must not start work") }
        XCTAssertFalse(model.isProcessing)
        XCTAssertTrue(fixture.transfers.packages.isEmpty)
        XCTAssertEqual(fixture.installation.leases, 0)
    }

    func testDisappearanceDuringImportBlocksLateSubmissionAndFeedback() async {
        let fixture = Fixture()
        fixture.installation.suspendsImport = true
        fixture.installation.warns = false
        let started = expectation(description: "import suspended")
        fixture.installation.importStarted = started
        let released = expectation(description: "late imported handle released")
        fixture.installation.onRelease = { released.fulfill() }
        let model = fixture.model()
        model.appear()
        var completed = 0
        model.startInstall { completed += 1 }
        await fulfillment(of: [started], timeout: 2)
        model.disappear()
        model.appear()
        XCTAssertNotNil(fixture.installation.activeLease)
        fixture.installation.completeImport()
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(fixture.installation.released, fixture.installation.imported)
        XCTAssertTrue(fixture.installation.submitted.isEmpty)
        XCTAssertTrue(fixture.platform.successes.isEmpty)
        XCTAssertTrue(fixture.platform.errors.isEmpty)
        XCTAssertEqual(completed, 0)
        XCTAssertFalse(model.isProcessing)
        XCTAssertEqual(model.statusMessage, "")
        model.disappear()
    }

    func testOldWarningCannotConfirmANewerPendingPackage() async throws {
        let fixture = Fixture()
        let firstPrompt = expectation(description: "first warning")
        fixture.platform.onPrompt = { firstPrompt.fulfill() }
        let model = fixture.model()
        model.appear()
        var completed = 0
        model.startInstall { completed += 1 }
        await fulfillment(of: [firstPrompt], timeout: 2)
        let oldConfirm = try XCTUnwrap(fixture.platform.confirmations.first)
        let first = try XCTUnwrap(fixture.installation.imported.first)
        let secondPrompt = expectation(description: "second warning")
        fixture.platform.onPrompt = { secondPrompt.fulfill() }
        model.startInstall { completed += 1 }
        await fulfillment(of: [secondPrompt], timeout: 2)
        let currentConfirm = try XCTUnwrap(fixture.platform.confirmations.last)
        let second = try XCTUnwrap(fixture.installation.imported.last)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(fixture.installation.released, [first])
        oldConfirm()
        XCTAssertTrue(fixture.installation.accepted.isEmpty)
        XCTAssertEqual(fixture.installation.released, [first])
        currentConfirm()
        currentConfirm() // A repeated UIKit callback cannot consume another offer.
        XCTAssertEqual(fixture.installation.accepted, [second])
        XCTAssertEqual(fixture.installation.released, [first, second])
        XCTAssertEqual(completed, 1)
        XCTAssertTrue(fixture.platform.errors.isEmpty)
        model.disappear()
    }

    func testWarningCannotResumeAfterDisappearanceAndReappearance() async throws {
        let fixture = Fixture()
        let prompt = expectation(description: "warning shown")
        fixture.platform.onPrompt = { prompt.fulfill() }
        let model = fixture.model()
        model.appear()
        var completed = 0
        model.startInstall { completed += 1 }
        await fulfillment(of: [prompt], timeout: 2)
        let confirm = try XCTUnwrap(fixture.platform.confirmations.first)
        model.disappear()
        model.appear()
        confirm()
        XCTAssertEqual(fixture.installation.released, fixture.installation.imported)
        XCTAssertTrue(fixture.installation.accepted.isEmpty)
        XCTAssertTrue(fixture.platform.successes.isEmpty)
        XCTAssertEqual(completed, 0)
        model.disappear()
    }

    func testConfirmationDisplaysTheActualGuestHandoffOutcome() async throws {
        let fixture = Fixture()
        let prompt = expectation(description: "warning shown")
        fixture.platform.onPrompt = { prompt.fulfill() }
        let model = fixture.model()
        model.appear()
        var completed = 0
        model.startInstall { completed += 1 }
        await fulfillment(of: [prompt], timeout: 2)
        // The existing owner re-resolves routing at confirmation time.
        fixture.installation.packageIsGuest = true
        let confirm = try XCTUnwrap(fixture.platform.confirmations.first)
        confirm()
        XCTAssertEqual(fixture.platform.successes.first?.image, "shippingbox")
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(fixture.installation.accepted, fixture.installation.imported)
        model.disappear()
    }

    func testDuplicateStartKeepsTheOriginallyReviewedMode() async {
        let fixture = Fixture()
        fixture.installation.warns = false
        let model = fixture.model()
        model.appear()
        let completed = expectation(description: "original installation request submitted")
        model.startInstall { completed.fulfill() }
        // Neither a changed field nor another Start may replace the captured mode
        // before the scheduled task first executes on the main actor.
        model.selectedMode = .signAndInstall
        model.startInstall { XCTFail("The active request must not be replaced") }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(fixture.transfers.packages.count, 1)
        XCTAssertTrue(fixture.installation.queued.isEmpty)
        XCTAssertEqual(fixture.installation.accepted.count, 1)
        XCTAssertTrue(fixture.platform.errors.isEmpty)
        model.disappear()
    }
}
