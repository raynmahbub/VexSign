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
//  The same goes for apps. The snapshot's rows are read once and the folders are
//  judged later, so a copy that is signed or imported in between has a folder and
//  no row. That is what a leftover looks like, and `clear(.leftovers)` deleted the
//  bundle of an app that had just been registered. The second half pins that a
//  copy this process is producing, or has produced, is not a leftover.
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

	// MARK: - Copies produced after the snapshot was taken

	/// A snapshot whose rows were read before anything below happened.
	private func earlierSnapshot(
		apps: [String: AppDescriptor] = [:],
		asking registry: AppOperationRegistry
	) -> LibrarySnapshot {
		LibrarySnapshot(apps: apps, certificates: [], protected: [], productions: registry)
	}

	func testACopyBeingProducedIsNotALeftover() {
		let registry = AppOperationRegistry()
		let library = earlierSnapshot(asking: registry)
		XCTAssertFalse(library.owns("new-copy", signed: true), "Nothing has announced it yet")

		// The run starts after the library was read. Its bundle is moved in, its row is not
		// committed yet: a folder with no row.
		let claim = registry.claimProduction(of: "new-copy")

		XCTAssertTrue(library.owns("new-copy", signed: true), "The folder is judged now, so it is asked about now")
		withExtendedLifetime(claim) {}
	}

	func testACopyProducedAndRegisteredSinceTheSnapshotIsNotALeftover() {
		let registry = AppOperationRegistry()
		let library = earlierSnapshot(asking: registry)

		// The whole run fits between reading the library and judging the folder: the row is
		// committed and the run is over, and the snapshot still has no row for it.
		var claim: AppOperationRegistry.Lease? = registry.claimProduction(of: "new-copy")
		registry.confirmProduction(of: "new-copy")
		XCTAssertNotNil(claim)
		claim = nil

		XCTAssertTrue(library.owns("new-copy", signed: true), "Deleting this folder would leave a row pointing at nothing")
	}

	func testWhatAFailedRunLeftBehindIsALeftoverAgain() {
		let registry = AppOperationRegistry()
		let library = earlierSnapshot(asking: registry)

		var claim: AppOperationRegistry.Lease? = registry.claimProduction(of: "abandoned")
		XCTAssertTrue(library.owns("abandoned", signed: true), "While the run is alive its folder is left alone")

		// The run fails or is cancelled: no row was committed, and the claim ends with the run.
		XCTAssertNotNil(claim)
		claim = nil

		XCTAssertFalse(library.owns("abandoned", signed: true), "Never registered, so it stays reclaimable")
	}

	func testAFolderNothingAccountsForIsStillALeftover() {
		let registry = AppOperationRegistry()
		let claim = registry.claimProduction(of: "new-copy")
		registry.confirmProduction(of: "registered-copy")
		let apps = ["known": AppDescriptor(name: "App", version: "1", date: Date(), isSigned: true)]
		let library = earlierSnapshot(apps: apps, asking: registry)

		XCTAssertFalse(library.owns("stray", signed: true), "Protecting what is produced must not protect everything")
		XCTAssertFalse(library.owns("stray", signed: false))
		XCTAssertFalse(library.owns("known", signed: false), "A row of the other kind still does not own the folder")
		XCTAssertTrue(library.owns("known", signed: true))
		withExtendedLifetime(claim) {}
	}

	func testCopiesBeingProducedDoNotMakeACertificateFolderOwned() {
		let registry = AppOperationRegistry()
		let claim = registry.claimProduction(of: "new-copy")
		let library = earlierSnapshot(asking: registry)

		XCTAssertFalse(library.ownsCertificate("new-copy"))
		withExtendedLifetime(claim) {}
	}

	func testASnapshotWithNothingToAskJudgesByItsRowsAlone() {
		// The memberwise initialiser stays source-compatible, and a snapshot built without a
		// registry behaves exactly as before.
		let apps = ["known": AppDescriptor(name: "App", version: "1", date: Date(), isSigned: true)]
		let library = LibrarySnapshot(apps: apps, certificates: [], protected: [])

		XCTAssertNil(library.productions)
		XCTAssertTrue(library.owns("known", signed: true))
		XCTAssertFalse(library.owns("anything-else", signed: true))
	}
}
