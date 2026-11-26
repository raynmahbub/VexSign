import Foundation
import XCTest
@testable import VexSign

@MainActor
final class LibraryWorkspaceBoundaryTests: XCTestCase {
    private final class Repository: LibraryRepository {
        var deleted: [[LibraryAppReference]] = []
        var orders: [[LibraryAppReference]] = []
        var imports: [URL] = []
        func importPackage(_ source: URL) async throws -> LibraryAppRecord { imports.append(source); return FeatureBoundaryFixtures.app() }
        func bundleURL(for app: LibraryAppReference) -> URL? { nil }
        func artifactURL(for app: LibraryAppReference) -> URL? { nil }
        func certificate(for app: LibraryAppReference) -> CertificateRecord? { nil }
        func deleteApps(_ apps: [LibraryAppReference]) throws { deleted.append(apps) }
        func renameApp(_ app: LibraryAppReference, name: String) throws {}
        func describeApp(_ app: LibraryAppReference, description: String?) throws {}
        func reorderApps(_ apps: [LibraryAppReference]) throws { orders.append(apps) }
    }
    private final class Cloner: LibraryCloningProviding {
        var calls: [LibraryAppReference] = []
        func clone(_ source: LibraryAppReference, request: LibraryCloneRequest) async throws -> LibraryAppRecord {
            calls.append(source); return FeatureBoundaryFixtures.app()
        }
    }

    func testMalformedSelectionIsRejectedBeforeAnyDelete() {
        let repository = Repository()
        let useCase = LibraryUseCase(repository: repository, cloning: Cloner())
        XCTAssertThrowsError(try useCase.delete([FeatureBoundaryFixtures.app(), FeatureBoundaryFixtures.app(uuid: nil)]))
        XCTAssertTrue(repository.deleted.isEmpty)
    }

    func testReorderRejectsDuplicatesAndMixedSignednessBeforeMutation() {
        let repository = Repository()
        let useCase = LibraryUseCase(repository: repository, cloning: Cloner())
        let app = FeatureBoundaryFixtures.app()
        XCTAssertThrowsError(try useCase.reorder([app, app]))
        XCTAssertThrowsError(try useCase.reorder([app, FeatureBoundaryFixtures.app(signed: true)]))
        XCTAssertTrue(repository.orders.isEmpty)
    }

    func testSameUUIDDoesNotConflateImportedAndSignedCopies() throws {
        let uuid = UUID().uuidString
        let imported = FeatureBoundaryFixtures.app(uuid: uuid)
        let signed = FeatureBoundaryFixtures.app(uuid: uuid, signed: true)
        XCTAssertNotEqual(try LibraryAppReference(app: imported), try LibraryAppReference(app: signed))
        XCTAssertNotEqual(imported.workspaceIdentity, signed.workspaceIdentity)
        let repository = Repository()
        let useCase = LibraryUseCase(repository: repository, cloning: Cloner())
        try useCase.delete([imported, signed])
        XCTAssertEqual(repository.deleted.first?.map(\.isSigned), [false, true])
    }

    func testHomeDropPolicyMatchesPackagePickerExtensions() {
        let policy = SecurityPolicyGateway()
        for ext in PackageArchiveType.pickerExtensions {
            XCTAssertTrue(policy.isAllowedPackageExtension(ext.uppercased()))
        }
        XCTAssertFalse(policy.isAllowedPackageExtension("p12"))
        XCTAssertFalse(policy.isAllowedPackageExtension("tgz"))
    }

    func testImportRejectsNetworkURLsAndNonPackagesBeforeStartingTheOwner() async throws {
        let repository = Repository()
        let useCase = LibraryUseCase(repository: repository, cloning: Cloner())
        for url in [URL(string: "https://example.com/app.ipa")!, URL(fileURLWithPath: "/fixture/identity.p12")] {
            do { _ = try await useCase.importPackage(url); XCTFail("Not a local package") }
            catch { XCTAssertEqual(error as? WorkspaceAccessError, .invalidReference) }
        }
        XCTAssertTrue(repository.imports.isEmpty)
        let urls = ["App.ipa", "App.TIPA", "App.ZIP"].map { URL(fileURLWithPath: "/fixture/" + $0) }
        for url in urls { _ = try await useCase.importPackage(url) }
        XCTAssertEqual(repository.imports, urls)
    }
}
