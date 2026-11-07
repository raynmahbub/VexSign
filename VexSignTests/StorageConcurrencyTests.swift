//
//  StorageConcurrencyTests.swift
//  VexSignTests
//
//  Covers the storage write boundary: writes started
//  from detached tasks run on the private-queue write context, hand back object
//  IDs instead of managed objects, and leave nothing behind when they fail.
//
//  Everything here uses a throwaway in-memory store, so it runs on any host
//  without touching the real library.
//

import CoreData
import XCTest
@testable import VexSign

final class StorageConcurrencyTests: XCTestCase {
	/// Shared with the task-group bodies below. `Storage` is not `Sendable` on
	/// purpose - a Core Data owner is queue-bound - so the fixture is a single
	/// per-test value rather than something captured from a local.
	private nonisolated(unsafe) static var storage: Storage!

	override func setUp() {
		super.setUp()
		Self.storage = Storage(inMemory: true)
	}

	override func tearDown() {
		Self.storage = nil
		super.tearDown()
	}

	// MARK: - Concurrent writes

	@MainActor
	func testConcurrentImportsCreateOneRowEach() async throws {
		try await withThrowingTaskGroup(of: Void.self) { group in
			for index in 0..<20 {
				group.addTask {
					try await Self.storage.addImported(
						uuid: "concurrent-\(index)",
						appName: "App \(index)",
						appIdentifier: "com.example.app\(index)",
						appVersion: "1.0"
					)
				}
			}
			try await group.waitForAll()
		}

		let rows = try Self.storage.context.fetch(Imported.fetchRequest())

		XCTAssertEqual(rows.count, 20, "every concurrent import must produce exactly one row")
		XCTAssertEqual(Set(rows.map { $0.uuid ?? "" }).count, 20)

		// An imported app keeps the identifier it was read with.
		XCTAssertTrue(rows.allSatisfy { $0.originalIdentifier == $0.identifier })

		// The library sorts by sortIndex. Writes are serialised on the write
		// context, so 20 simultaneous inserts still get 20 distinct values - two
		// independent background contexts would all have read the same lowest
		// value and collided.
		XCTAssertEqual(Set(rows.map { $0.sortIndex }).count, 20)
	}

	@MainActor
	func testConcurrentSignedAndImportedWritesStayConsistent() async throws {
		try await withThrowingTaskGroup(of: Void.self) { group in
			for index in 0..<10 {
				group.addTask {
					try await Self.storage.addSigned(
						uuid: "signed-\(index)",
						appName: "Signed \(index)",
						appIdentifier: "com.example.signed\(index)",
						originalAppIdentifier: "com.example.original\(index)",
						appVersion: "1.0"
					)
				}
				group.addTask {
					try await Self.storage.addImported(
						uuid: "imported-\(index)",
						appName: "Imported \(index)",
						appIdentifier: "com.example.imported\(index)",
						appVersion: "1.0"
					)
				}
			}
			try await group.waitForAll()
		}

		let signed = try Self.storage.context.fetch(Signed.fetchRequest())
		let imported = try Self.storage.context.fetch(Imported.fetchRequest())

		XCTAssertEqual(signed.count, 10)
		XCTAssertEqual(imported.count, 10)

		// Two entity types share one write context; each still gets its own range
		// of sortIndex values.
		XCTAssertEqual(Set(signed.map { $0.sortIndex }).count, 10)
		XCTAssertEqual(Set(imported.map { $0.sortIndex }).count, 10)

		XCTAssertEqual(Self.storage.getAllApps().count, 20)
	}

	// MARK: - Deletion from the main queue

	/// `deleteApps` is guarded by the main-queue tripwire, because it
	/// deletes through the view context. This runs the same path the library UI
	/// uses: insert off-main through `write`, then delete on main.
	@MainActor
	func testDeletingAfterABackgroundInsertRemovesTheRow() async throws {
		let id = try await Self.storage.addImported(
			uuid: "imported-to-delete",
			appName: "Delete Me",
			appIdentifier: "com.example.delete"
		)

		let row: Imported = try XCTUnwrap(Self.storage.object(id))
		Self.storage.deleteApp(for: row)

		let remaining = try Self.storage.context.fetch(Imported.fetchRequest())
		XCTAssertTrue(remaining.isEmpty, "The row must be gone after a main-queue delete")
	}

	/// The library deletes a signed copy through the same path. A signed row carries a
	/// certificate relationship, which an imported row does not have — and #113 reports that
	/// only the signed copies refuse to go.
	@MainActor
	func testDeletingASignedAppRemovesTheRow() async throws {
		let certificateID = try await Self.storage.write { context in
			let certificate = CertificatePair(context: context)
			certificate.uuid = "cert-delete"
			certificate.date = Date()
			certificate.ppQCheck = false
			certificate.isDefault = false
			certificate.revoked = false
			return certificate
		}

		let id = try await Self.storage.addSigned(
			uuid: "signed-to-delete",
			certificateID: certificateID,
			appName: "Signed Delete Me",
			appIdentifier: "com.example.signed.delete"
		)

		let row: Signed = try XCTUnwrap(Self.storage.object(id))
		XCTAssertTrue(Self.storage.deleteApp(for: row), "a delete that works must report success")

		let remaining = try Self.storage.context.fetch(Signed.fetchRequest())
		XCTAssertTrue(remaining.isEmpty, "The signed row must be gone after a main-queue delete")
	}

	// MARK: - Object IDs

	@MainActor
	func testReturnedIdentifiersResolveOnTheMainContext() async throws {
		let certificateID = try await Self.storage.write { context in
			let certificate = CertificatePair(context: context)
			certificate.uuid = "cert-1"
			certificate.date = Date()
			// Non-optional in the model: set them rather than relying on defaults.
			certificate.ppQCheck = false
			certificate.isDefault = false
			certificate.revoked = false
			return certificate
		}

		let signedID = try await Self.storage.addSigned(
			uuid: "signed-1",
			certificateID: certificateID,
			appName: "Signed App",
			appIdentifier: "com.example.signed.new",
			originalAppIdentifier: "com.example.signed.original",
			appVersion: "1.0"
		)

		let importedID = try await Self.storage.addImported(
			uuid: "imported-1",
			appName: "Imported App",
			appIdentifier: "com.example.imported",
			appVersion: "2.0"
		)

		let signed: Signed? = Self.storage.object(signedID)
		let imported: Imported? = Self.storage.object(importedID)

		XCTAssertEqual(signed?.uuid, "signed-1")
		XCTAssertEqual(signed?.identifier, "com.example.signed.new")
		// The identifier before PPQ protection / bundle-ID changes is preserved.
		XCTAssertEqual(signed?.originalIdentifier, "com.example.signed.original")
		// The certificate is attached by object ID and re-fetched on the write
		// context, so the relationship is intact on the main context.
		XCTAssertEqual(signed?.certificate?.uuid, "cert-1")
		XCTAssertEqual(imported?.originalIdentifier, "com.example.imported")
	}

	// MARK: - Failure handling

	@MainActor
	func testFailedWriteLeavesNoRowBehind() async throws {
		enum WriteFailure: Error { case rejected }

		do {
			_ = try await Self.storage.write { context -> NSManagedObject in
				let row = Imported(context: context)
				row.uuid = "half-written"
				throw WriteFailure.rejected
			}
			XCTFail("A throwing write must not report success")
		} catch is WriteFailure {
			// Expected: the context was rolled back.
		}

		let remaining = try Self.storage.context.count(for: Imported.fetchRequest())
		XCTAssertEqual(remaining, 0, "the rolled-back insert must not survive")
	}

	@MainActor
	func testInMemoryStoreIsEmptyAndDetachedFromTheLibrary() async throws {
		XCTAssertTrue(Self.storage.getAllApps().isEmpty)
		XCTAssertTrue(Self.storage.getAllCertificates().isEmpty)

		// Writing still works on a fresh store, and the row is only visible to
		// this container - the real library is a different store entirely.
		_ = try await Self.storage.addImported(uuid: "fresh", appIdentifier: "com.example.fresh")
		XCTAssertEqual(Self.storage.getAllApps().count, 1)
	}
}
