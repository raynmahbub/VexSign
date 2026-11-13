//
//  DeviceAppRemovalTests.swift
//  VexSignTests
//
//  Removing an app from the paired device: what is refused, and what each outcome may claim.
//  No device is involved; the transport and the probe are stand-ins.
//

import XCTest
@testable import VexSign

final class DeviceAppRemovalTests: XCTestCase {
	private final class Uninstaller: DeviceAppUninstalling, @unchecked Sendable {
		private let lock = NSLock()
		private var _requests: [String] = []
		let error: Error?

		init(error: Error? = nil) { self.error = error }

		var requests: [String] {
			lock.lock(); defer { lock.unlock() }
			return _requests
		}

		func uninstall(bundleIdentifier: String) async throws {
			lock.lock()
			_requests.append(bundleIdentifier)
			lock.unlock()
			if let error { throw error }
		}
	}

	private struct Probe: InstalledAppProbing {
		let reading: InstalledApp?
		func installedApp(for bundleIdentifier: String) -> InstalledApp? { reading }
	}

	private struct Refused: LocalizedError {
		var errorDescription: String? { "device said no" }
	}

	private func remove(
		_ identifier: String = "com.example.app",
		uninstaller: Uninstaller,
		reading: InstalledApp?
	) async -> DeviceAppRemoval.Outcome {
		await DeviceAppRemoval.remove(
			bundleIdentifier: identifier,
			ownBundleIdentifier: "com.vexsign.app",
			uninstaller: uninstaller,
			probe: Probe(reading: reading),
			settle: .zero
		)
	}

	// MARK: - Refusals

	func testIdentifiersThatAreNotBundleIdentifiersAreRefused() {
		for identifier in ["", "   ", "nodots", "com.example/../x", "com.example app", "com.exämple.app", String(repeating: "a.", count: 200)] {
			XCTAssertEqual(
				DeviceAppRemoval.refusal(for: identifier, ownBundleIdentifier: nil), .invalidIdentifier, identifier
			)
		}
		XCTAssertNil(DeviceAppRemoval.refusal(for: " com.example.my-app_2 ", ownBundleIdentifier: nil))
	}

	func testVexSignItselfAndSystemAppsAreRefused() {
		XCTAssertEqual(DeviceAppRemoval.refusal(for: "com.VexSign.App", ownBundleIdentifier: "com.vexsign.app"), .ownApp)
		XCTAssertEqual(DeviceAppRemoval.refusal(for: "com.apple.mobilesafari", ownBundleIdentifier: "com.vexsign.app"), .systemApp)
		XCTAssertNil(DeviceAppRemoval.refusal(for: "com.applesauce.app", ownBundleIdentifier: "com.vexsign.app"))
	}

	func testARefusedRemovalNeverReachesTheDevice() async {
		for identifier in ["com.vexsign.app", "com.apple.Preferences", "not an identifier"] {
			let uninstaller = Uninstaller()
			let outcome = await remove(identifier, uninstaller: uninstaller, reading: nil)
			guard case .refused = outcome else { return XCTFail("\(identifier): \(outcome)") }
			XCTAssertEqual(uninstaller.requests, [], identifier)
		}
	}

	// MARK: - Outcomes

	func testRemovedNeedsTheDeviceToReportTheAppAbsent() async {
		let uninstaller = Uninstaller()
		let outcome = await remove(
			uninstaller: uninstaller,
			reading: InstalledApp(bundleIdentifier: "com.example.app", isInstalled: false)
		)
		XCTAssertEqual(outcome, .removed)
		XCTAssertEqual(uninstaller.requests, ["com.example.app"], "Asked once, with the trimmed identifier")
	}

	func testAnUnreadableDeviceIsRequestedNotRemoved() async {
		let outcome = await remove(uninstaller: Uninstaller(), reading: nil)
		XCTAssertEqual(outcome, .requested)
	}

	func testAPlaceholderIsNotAReading() {
		XCTAssertEqual(
			DeviceAppRemoval.outcome(after: InstalledApp(bundleIdentifier: "x.y", isInstalled: true, isPlaceholder: true)),
			.requested
		)
	}

	func testAnAppTheDeviceStillReportsIsNotCalledRemoved() async {
		let outcome = await remove(
			uninstaller: Uninstaller(),
			reading: InstalledApp(bundleIdentifier: "com.example.app", isInstalled: true)
		)
		XCTAssertEqual(outcome, .stillInstalled)
	}

	func testADeviceErrorIsAFailureEvenIfTheAppLooksAbsent() async {
		let outcome = await remove(
			uninstaller: Uninstaller(error: Refused()),
			reading: InstalledApp(bundleIdentifier: "com.example.app", isInstalled: false)
		)
		XCTAssertEqual(outcome, .failed("device said no"))
	}

	func testEveryOutcomeSaysSomething() {
		let outcomes: [DeviceAppRemoval.Outcome] = [
			.removed, .requested, .stillInstalled, .failed("x"),
			.refused(.ownApp), .refused(.systemApp), .refused(.invalidIdentifier)
		]
		for outcome in outcomes {
			XCTAssertFalse(outcome.title.isEmpty)
			XCTAssertFalse(outcome.message.isEmpty)
		}
		XCTAssertNotEqual(DeviceAppRemoval.Outcome.requested.title, DeviceAppRemoval.Outcome.removed.title)
	}
}
