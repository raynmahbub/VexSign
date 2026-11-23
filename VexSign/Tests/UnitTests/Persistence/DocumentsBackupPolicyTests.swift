//
//  DocumentsBackupPolicyTests.swift
//  VexSignTests
//
//  Documents is Files-visible (`UIFileSharingEnabled`), so everything the app writes
//  there also rides into an iCloud/iTunes device backup unless it is flagged. The
//  policy is: derived or diagnostic folders are excluded, user content is not. These
//  tests pin both halves, because a one-line regression either bloats every backup
//  with re-downloadable firmware or silently drops the user's own library.
//

import XCTest
@testable import VexSign

final class DocumentsBackupPolicyTests: XCTestCase {

	private let fileManager = FileManager.default

	override func setUp() {
		super.setUp()
		BackgroundAndLifecyclePlatform.ensureDocumentsDirectories(fileManager: fileManager)
	}

	func testDerivedFoldersAreExcludedFromDeviceBackups() throws {
		let derived: [(String, URL)] = [
			("Firmware", fileManager.firmware),
			("Web Manager inbox", fileManager.webManagerInbox),
			("Logs", fileManager.logs)
		]
		for (name, url) in derived {
			XCTAssertTrue(fileManager.fileExists(atPath: url.path), "\(name) should exist after the launch sweep")
			let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
			XCTAssertEqual(excluded, true, "\(name) is derived data and must not ride in a device backup")
		}
	}

	func testLibraryFoldersStayInDeviceBackups() throws {
		// The user's own apps are the one thing a device backup is *for*. Excluding
		// them would make "restore my phone" lose the library with no warning.
		let library: [(String, URL)] = [
			("Archives", fileManager.archives),
			("Signed", fileManager.signed),
			("Unsigned", fileManager.unsigned)
		]
		for (name, url) in library {
			let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
			XCTAssertNotEqual(excluded, true, "\(name) holds user content and must stay in a device backup")
		}
	}

	func testExcludingAMissingDirectoryIsANoOp() {
		// The sweep must not fail a launch because a folder was already cleaned up.
		let missing = fileManager.temporaryDirectory.appendingPathComponent("vexsign-absent-\(UUID().uuidString)")
		XCTAssertFalse(fileManager.excludeFromBackup(missing))
	}
}
