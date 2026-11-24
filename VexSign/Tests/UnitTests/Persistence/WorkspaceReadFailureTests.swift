import CoreData
import XCTest
@testable import VexSign

@MainActor
final class WorkspaceReadFailureTests: XCTestCase {
    /// A read that fails must be reported, not turned into "no rows".
    ///
    /// The library snapshot is built from these reads. When a failure became an empty array the
    /// Library rendered an empty store, so a committed import looked like an import that never
    /// happened. The throwing accessor is the one the catalog path uses.
    func testAReadThatThrowsIsReportedInsteadOfReturningNoRows() {
        let storage = Storage(inMemory: true)
        // An entity this model does not contain: `fetch` throws rather than returning rows,
        // which is the same shape as a store that cannot be read.
        let request = NSFetchRequest<NSManagedObject>(entityName: "NotAnEntityInThisModel")

        // Core Data raises for this request rather than failing it, so the accessor answers from
        // the model first: a name the model does not carry is an error here, not a crash.
        XCTAssertThrowsError(try storage.fetchOnQueueThrowing(request)) { error in
            XCTAssertEqual(error as? Storage.ReadFailure, .unknownEntity("NotAnEntityInThisModel"))
        }

        // The non-throwing accessor keeps its "empty is a valid answer" contract for the
        // optional lookups that rely on it.
        XCTAssertEqual(storage.fetchOnQueue(request).count, 0)
    }

    /// The catalog read of an empty store succeeds with no rows — failure and emptiness are
    /// different answers and must stay distinguishable.
    func testAnEmptyStoreReadsAsEmptyRatherThanFailing() throws {
        let storage = Storage(inMemory: true)
        let repository = CoreDataWorkspaceRepository(storage: storage)

        let snapshot = try repository.readWorkspace()

        XCTAssertTrue(snapshot.signedApps.isEmpty)
        XCTAssertTrue(snapshot.importedApps.isEmpty)
        XCTAssertTrue(snapshot.certificates.isEmpty)
        XCTAssertTrue(snapshot.repositories.isEmpty)
        XCTAssertEqual(storage.fetchOnQueue(Signed.fetchRequest()).count, 0)
    }
}
