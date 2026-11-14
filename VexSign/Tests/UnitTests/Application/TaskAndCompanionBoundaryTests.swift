import Foundation
import XCTest
@testable import VexSign

@MainActor
final class TaskAndCompanionBoundaryTests: XCTestCase {
    private final class Tasks: TaskWorkspaceProviding {
        var retried: [(String, Bool)] = []
        func state() -> TaskWorkspaceState { TaskWorkspaceState() }
        func changes() -> AsyncStream<TaskWorkspaceState> { AsyncStream { $0.finish() } }
        func iconData(taskID: String) -> Data? { nil }
        func retry(taskID: String, allowingUnconfirmedInstall: Bool) -> Bool { retried.append((taskID, allowingUnconfirmedInstall)); return true }
        func removeHistory(taskID: String) -> Bool { false }
        func restoreHistory(taskID: String) -> Bool { false }
        func clearHistory() {}
        func reverifyDownload(id: UUID) {}
        func retryDownload(id: UUID) {}
        func forgetDownload(id: UUID) {}
    }
    private final class Companion: CompanionArchivePreparing {
        var staged: [URL] = []
        var embedded: [URL] = []
        var shared: [URL] = []
        var removed: [URL] = []
        func prepareLibrary(_ app: LibraryAppReference, progress: @escaping @MainActor (Double) -> Void) async throws -> URL { URL(fileURLWithPath: "/fixture/owned.ipa") }
        func stage(_ source: URL) async throws -> URL { staged.append(source); return source }
        func prepareEmbeddedImport(_ stagedURL: URL) async throws -> Bool { embedded.append(stagedURL); return true }
        func share(_ stagedURL: URL) throws { shared.append(stagedURL) }
        func remove(_ stagedURL: URL) throws { removed.append(stagedURL) }
    }

    func testUnconfirmedInstallRequiresASeparateExplicitRetryDecision() {
        let provider = Tasks()
        let useCase = TaskWorkspaceUseCase(provider: provider)
        let record = FeatureBoundaryFixtures.task()
        XCTAssertFalse(useCase.retry(record))
        XCTAssertTrue(provider.retried.isEmpty)
        XCTAssertTrue(useCase.retry(record, allowingUnconfirmedInstall: true))
        XCTAssertEqual(provider.retried.first?.0, record.id)
        XCTAssertEqual(provider.retried.first?.1, true)
    }

    func testOrdinaryRetryDoesNotManufactureHandoffConsent() {
        let provider = Tasks()
        let useCase = TaskWorkspaceUseCase(provider: provider)
        XCTAssertTrue(useCase.retry(FeatureBoundaryFixtures.task(kind: .sign, unknown: false)))
        XCTAssertEqual(provider.retried.first?.1, false)
    }

    func testCompanionPreparationIsNotAutomaticallySharedOrOpened() async throws {
        let provider = Companion()
        let useCase = CompanionArchiveUseCase(provider: provider)
        let url = URL(fileURLWithPath: "/fixture/source.ipa")
        let staged = try await useCase.stage(url)
        XCTAssertEqual(provider.staged, [url])
        XCTAssertTrue(provider.shared.isEmpty)
        XCTAssertTrue(provider.embedded.isEmpty)
        let accepted = try await useCase.prepareEmbeddedImport(staged)
        XCTAssertTrue(accepted, "This is only the fake host-inbox preparation answer")
        XCTAssertEqual(provider.embedded, [staged])
        XCTAssertTrue(provider.shared.isEmpty)
        try useCase.remove(staged)
        XCTAssertEqual(provider.removed, [staged])
    }

    func testNonIPACompanionSourceIsRejected() async {
        let provider = Companion()
        let useCase = CompanionArchiveUseCase(provider: provider)
        do { _ = try await useCase.stage(URL(fileURLWithPath: "/fixture/key.p12")); XCTFail("Not an IPA") }
        catch { XCTAssertEqual(error as? WorkspaceAccessError, .invalidReference) }
        XCTAssertTrue(provider.staged.isEmpty)
    }
}
