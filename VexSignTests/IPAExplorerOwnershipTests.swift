import CoreData
import XCTest
@testable import VexSign

@MainActor
final class IPAExplorerOwnershipTests: XCTestCase {
    private func fixture() throws -> (Storage, Imported, IPAWorkspace) {
        let storage = Storage(inMemory: true)
        let row = Imported(context: storage.context)
        row.uuid = UUID().uuidString
        row.name = "Editor ownership fixture"
        try storage.context.save()
        let container = try XCTUnwrap(storage.getUuidDirectory(for: row))
        try FileManager.default.createDirectory(at: container.appendingPathComponent("Fixture.app"), withIntermediateDirectories: true)
        return (storage, row, try IPAWorkspace.open(app: row))
    }

    func testBusyLibraryCopyRejectsEveryFileActionWithoutMutation() throws {
        let (storage, row, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: workspace.containerURL) } // try? ok: test teardown only
        let file = workspace.appURL.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: file)
        let replacement = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: replacement) } // try? ok: test teardown only
        try Data("replacement".utf8).write(to: replacement)
        let entry = IPAFileEntry(url: file, name: "original.txt", isDirectory: false,
                                 size: 8, date: Date(), kind: .text, childCount: 0)
        let lease = try AppOperationRegistry.shared.acquire(AppOperationRegistry.key(row))
        defer { withExtendedLifetime((storage, lease)) {} }
        XCTAssertThrowsError(try workspace.acquireEditingLease())
        XCTAssertNil(IPAExplorerActions.createFolder(named: "blocked", in: workspace.appURL, workspace: workspace))
        XCTAssertNil(IPAExplorerActions.rename(entry, to: "renamed.txt", workspace: workspace))
        XCTAssertFalse(IPAExplorerActions.replace(entry, with: replacement, workspace: workspace))
        XCTAssertEqual(IPAExplorerActions.importFiles([replacement], into: workspace.appURL, workspace: workspace), 0)
        IPAExplorerActions.delete(entry, workspace: workspace)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.appURL.path), ["original.txt"])
        XCTAssertEqual(workspace.changeCount, 0)
    }

    func testEditingLeaseBlocksLibraryDeletionAndReleasesAfterScope() throws {
        let (storage, row, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: workspace.containerURL) } // try? ok: test teardown only
        do {
            let lease = try workspace.acquireEditingLease()
            defer { withExtendedLifetime(lease) {} }
            XCTAssertFalse(storage.deleteApps([row]))
            XCTAssertFalse(row.isDeleted)
            XCTAssertThrowsError(try AppOperationRegistry.shared.acquire(AppOperationRegistry.key(row)))
        }
        XCTAssertFalse(AppOperationRegistry.shared.isBusy(AppOperationRegistry.key(row)))
        XCTAssertNotNil(IPAExplorerActions.createFolder(named: "allowed", in: workspace.appURL, workspace: workspace))
        XCTAssertEqual(workspace.changeCount, 1)
    }

    func testDeletedWorkspaceCannotRecreateLibraryFilesOrLeakLease() throws {
        let (storage, row, workspace) = try fixture()
        defer { withExtendedLifetime(storage) {} }
        try FileManager.default.removeItem(at: workspace.containerURL)
        XCTAssertThrowsError(try workspace.acquireEditingLease())
        XCTAssertNil(IPAExplorerActions.createFolder(named: "blocked", in: workspace.appURL, workspace: workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.containerURL.path))
        XCTAssertFalse(AppOperationRegistry.shared.isBusy(AppOperationRegistry.key(row)))
    }

    func testImportBatchDoesNotReacquireItsOwnLease() throws {
        let (storage, _, workspace) = try fixture()
        defer { withExtendedLifetime(storage) {} }
        defer { try? FileManager.default.removeItem(at: workspace.containerURL) } // try? ok: test teardown only
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) } // try? ok: test teardown only
        try Data("imported".utf8).write(to: source)
        XCTAssertEqual(IPAExplorerActions.importFiles([source], into: workspace.appURL, workspace: workspace), 1)
        XCTAssertEqual(try Data(contentsOf: workspace.appURL.appendingPathComponent(source.lastPathComponent)), Data("imported".utf8))
    }
}
