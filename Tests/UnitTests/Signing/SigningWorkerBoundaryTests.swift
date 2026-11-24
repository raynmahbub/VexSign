import CoreData
import XCTest
@testable import VexSign

@MainActor
final class SigningWorkerBoundaryTests: XCTestCase {
    func testRequestProjectsAnImmutableLibraryRecordToTheWorker() {
        let record = LibraryAppRecord(
            id: "record-1", uuid: "app-1", isSigned: false, name: "Fixture",
            version: "1.0", identifier: "com.example.fixture", originalIdentifier: nil,
            date: Date(timeIntervalSince1970: 1_700_000_000), icon: nil, appDescription: nil,
            sortIndex: 0, source: URL(string: "https://repo.example.invalid/catalog.json"),
            certificateID: nil, bundleURL: nil, artifactURL: nil
        )
        let request = SigningRequest(app: record, options: .defaultOptions, icon: nil, certificate: nil)

        let worker = request.workerValue()

        XCTAssertTrue(worker.appReferenceIsValid)
        XCTAssertEqual(worker.id, request.id)
        XCTAssertEqual(worker.app.recordID, record.recordID)
        XCTAssertEqual(worker.app.uuid, record.uuid)
        XCTAssertEqual(worker.app.name, record.name)
        XCTAssertEqual(worker.app.source, record.source)
        XCTAssertNil(worker.iconData)
        XCTAssertNil(worker.certificateID)
    }

    func testForeignManagedAppDoesNotEscapeIntoTheWorkerSnapshot() {
        let foreignStorage = Storage(inMemory: true)
        let app = Signed(context: foreignStorage.context)
        app.uuid = "foreign-app"
        app.name = "Foreign"
        let request = SigningRequest(app: app, options: .defaultOptions, icon: nil, certificate: nil)

        let worker = request.workerValue()

        XCTAssertFalse(worker.appReferenceIsValid)
        XCTAssertNil(worker.app.uuid, "A rejected Core Data object is not read or retained off its owning context")
    }
}
