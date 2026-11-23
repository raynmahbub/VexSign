//
//  AppClonerTests.swift
//  VexSignTests
//
//  Cloning copies an app's bundle and registers a new library entry. The guards
//  below run before any data is written: a clone of an app that is not on disk
//  must fail loudly and leave nothing behind, rather than registering an empty row.
//

import XCTest
@testable import VexSign

@MainActor
final class AppClonerTests: XCTestCase {

	private struct FakeApp: AppInfoPresentable {
		var name: String? = "DemoApp"
		var version: String? = "1.0.0"
		var identifier: String? = "com.example.demo"
		var originalIdentifier: String? = "com.example.demo"
		var date: Date? = Date()
		var icon: String? = nil
		var uuid: String? = "demo-uuid"
		var isSigned: Bool = false
		var appDescription: String? = nil
	}

	func testCloningAnAppThatIsNotOnDiskFailsWithoutCreatingAFolder() async {
		let uuid = "clone-test-\(UUID().uuidString)"
		let destination = FileManager.default.unsigned(uuid)
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "precondition: nothing staged")

		do {
			_ = try await AppCloner.shared.clone(app: FakeApp(uuid: uuid))
			XCTFail("a clone of a missing app must not succeed")
		} catch {
			XCTAssertEqual(error as? AppCloner.CloneError, .appNotFound)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
		               "a refused clone must not leave a half-copied directory behind")
	}

	func testACloneWithoutAnIdentityIsRefused() async {
		do {
			_ = try await AppCloner.shared.clone(app: FakeApp(uuid: nil))
			XCTFail("an app row without a uuid cannot address a directory and must be refused")
		} catch {
			XCTAssertEqual(error as? AppCloner.CloneError, .appNotFound)
		}
	}
}
