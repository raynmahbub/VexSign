//
//  InstallQueueTransitionTests.swift
//  VexSignTests
//
//  The queue's transitions were the least covered part of it: `pause`/`resume`/`canSkip`
//  appear in tests, `advance`, `activate`, `reconcileOnForeground` and `sheetDismissed`
//  appeared in none. Those four need the shared singletons (`UnifiedTaskCenter`,
//  `InstallQueueWindow`, `UIApplication.shared`) and a live `AppInstaller`, so they cannot be
//  driven directly here — see `Makefile` (`make test`) for that gap and the seam
//  it needs. What *is* pure is the method mapping every one of those branches keys off, and
//  the preparation rule built on it; those are pinned below.
//

import XCTest
@testable import VexSign

@MainActor
final class InstallQueueTransitionTests: XCTestCase {

	// MARK: - installationMethod

	func testExportResolvesToZeroWithoutConsultingThePipeline() {
		var consulted = false
		let method = InstallQueue.installationMethod(isExport: true) {
			consulted = true
			return 2
		}
		XCTAssertEqual(method, 0, "Exports bypass app routing entirely")
		XCTAssertFalse(consulted, "An export must not touch SigningModeManager")
	}

	func testUnresolvedPipelineBecomesInvalidNotZero() {
		enum Route: Error { case unresolved }
		let method = InstallQueue.installationMethod(isExport: false) { throw Route.unresolved }
		XCTAssertEqual(method, -1, "Falling back to 0 would silently claim the app is OTA-installable")
	}

	func testPipelineCodesPassThrough() {
		XCTAssertEqual(InstallQueue.installationMethod(isExport: false) { 0 }, 0)
		XCTAssertEqual(InstallQueue.installationMethod(isExport: false) { 2 }, 2)
	}

	// MARK: - Preparation depends on that mapping

	func testPreparationOnlyOverlapsOTAWork() {
		// The lookahead in `_prepareNext` is gated on the *next* item being OTA (0) and
		// neither item being an export. Pin the table so the two rules stay in step.
		XCTAssertTrue(InstallPreparationPolicy.allows(installationMethod: 0, currentIsExport: false, nextIsExport: false))
		XCTAssertFalse(InstallPreparationPolicy.allows(installationMethod: 2, currentIsExport: false, nextIsExport: false))
		XCTAssertFalse(InstallPreparationPolicy.allows(installationMethod: -1, currentIsExport: false, nextIsExport: false))
		XCTAssertFalse(InstallPreparationPolicy.allows(installationMethod: 0, currentIsExport: true, nextIsExport: false))
		XCTAssertFalse(InstallPreparationPolicy.allows(installationMethod: 0, currentIsExport: false, nextIsExport: true))
	}

	func testAnUnresolvedRouteNeverLooksPreparable() {
		let next = InstallQueue.installationMethod(isExport: false) {
			throw CocoaError(.featureUnsupported)
		}
		XCTAssertFalse(InstallPreparationPolicy.allows(installationMethod: next, currentIsExport: false, nextIsExport: false))
	}
}
