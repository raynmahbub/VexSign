//
//  StorageLibrarySnapshotTests.swift
//  VexSignTests
//
//  Cleanup decides what to delete from a LibrarySnapshot. If the certificate
//  fetch fails, the snapshot carries an empty certificate set — and an empty set
//  used to mean "no certificates installed", so `clear(.leftovers)` treated every
//  certificate on disk as an orphan and deleted it. These tests pin the fail-closed
//  behaviour: unknown is not none.
//
//  Pure value-type tests: no filesystem, no CoreData, no simulator state.
//

import Foundation
import XCTest
@testable import VexSign

final class StorageLibrarySnapshotTests: XCTestCase {
	private func snapshot(certificates: Set<String>, known: Bool = true) -> LibrarySnapshot {
		LibrarySnapshot(apps: [:], certificates: certificates, protected: [], certificatesKnown: known)
	}

	func testKnownCertificateIsOwned() {
		let library = snapshot(certificates: ["A", "B"])
		XCTAssertTrue(library.ownsCertificate("A"))
		XCTAssertTrue(library.ownsCertificate("B"))
	}

	func testUnknownUuidIsAnOrphanWhenTheListIsComplete() {
		let library = snapshot(certificates: ["A"])
		XCTAssertFalse(library.ownsCertificate("stray"),
					   "A directory no certificate claims is a leftover and must stay reclaimable")
	}

	func testEmptyButKnownListStillLeavesOrphansReclaimable() {
		// Genuinely no certificates installed: the files really are leftovers.
		let library = snapshot(certificates: [])
		XCTAssertFalse(library.ownsCertificate("stray"))
	}

	func testFailedFetchProtectsEveryCertificate() {
		let library = snapshot(certificates: [], known: false)
		XCTAssertTrue(library.ownsCertificate("A"))
		XCTAssertTrue(library.ownsCertificate("B"))
		XCTAssertTrue(library.ownsCertificate("anything-at-all"),
					  "A failed fetch must not turn installed certificates into deletable leftovers")
	}

	func testFailedFetchWithAPartialListProtectsTheRestToo() {
		let library = snapshot(certificates: ["A"], known: false)
		XCTAssertTrue(library.ownsCertificate("A"))
		XCTAssertTrue(library.ownsCertificate("B"))
	}

	func testCertificatesAreAssumedKnownByDefault() {
		// The memberwise initialiser stays source-compatible for existing callers,
		// and the default must be the ordinary, complete-list case.
		let library = LibrarySnapshot(apps: [:], certificates: ["A"], protected: [])
		XCTAssertTrue(library.certificatesKnown)
		XCTAssertTrue(library.ownsCertificate("A"))
		XCTAssertFalse(library.ownsCertificate("B"))
	}

	func testAppOwnershipIsUnaffectedByTheCertificateFlag() {
		let apps = ["signed-1": AppDescriptor(name: "App", version: "1", date: Date(), isSigned: true)]
		let library = LibrarySnapshot(apps: apps, certificates: [], protected: [], certificatesKnown: false)
		XCTAssertTrue(library.owns("signed-1", signed: true))
		XCTAssertFalse(library.owns("signed-1", signed: false))
		XCTAssertFalse(library.owns("missing", signed: true))
	}

	func testProtectedPathsCoverTheFileAndItsAncestors() {
		// `protects` answers "does this path hold something protected", so a parent
		// of the database is protected too — otherwise cleanup deletes the store
		// by deleting the folder above it.
		let library = LibrarySnapshot(apps: [:], certificates: [], protected: ["/db/store.sqlite"])
		XCTAssertTrue(library.protects(URL(fileURLWithPath: "/db/store.sqlite")))
		XCTAssertTrue(library.protects(URL(fileURLWithPath: "/db")))
		XCTAssertFalse(library.protects(URL(fileURLWithPath: "/db/store.sqlite-wal")))
		XCTAssertFalse(library.protects(URL(fileURLWithPath: "/elsewhere")))
	}
}
