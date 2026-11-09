//
//  ProtectedFileAttributesTests.swift
//  VexSignTests
//
//  Regression tests for the two simulator failures in #136.
//
//  `ProtectedCertificateFiles.migrate` applied `.protectionKey` with `setAttributes`. The iOS
//  simulator has no data-protection classes, so that call is refused there — and because it
//  runs *before* the first move, migration aborted with nothing copied:
//
//    testPartialCertificateMigrationCanResumeWithoutOverwrite  → destination/a.p12 missing
//    testDirectoryFailureReportsWarningAndRetainsOriginalBytes → fell back to the legacy URL
//
//  The refusal is now tolerated (there is no protection class to set on that volume) while
//  every other error still propagates, so a device cannot silently lose protection. The seam
//  is injected here, which means these tests assert the policy on any host rather than
//  depending on which filesystem the simulator happens to use.
//

import Foundation
import XCTest
@testable import VexSign

final class ProtectedFileAttributesTests: XCTestCase {
	private let path = "/fixture/identity.p12"

	private var attributes: [FileAttributeKey: Any] {
		[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o600]
	}

	// MARK: - Classification

	func testUnsupportedProtectionIsRecognised() {
		XCTAssertTrue(ProtectedCertificateFiles.isDataProtectionUnsupported(
			NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))))
		XCTAssertTrue(ProtectedCertificateFiles.isDataProtectionUnsupported(
			NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)))
	}

	func testUnsupportedProtectionIsRecognisedThroughAnUnderlyingError() {
		let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
			NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
		])
		XCTAssertTrue(ProtectedCertificateFiles.isDataProtectionUnsupported(wrapped))
	}

	func testRealFailuresAreNotMistakenForMissingSupport() {
		for error in [
			NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
			NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
			NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
			NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
		] {
			XCTAssertFalse(ProtectedCertificateFiles.isDataProtectionUnsupported(error), "\(error)")
		}
	}

	// MARK: - Application policy

	func testSupportedVolumeGetsTheWholeAttributeSetInOneCall() throws {
		var calls: [[FileAttributeKey: Any]] = []
		try ProtectedCertificateFiles.applyProtectionAttributes(attributes, at: path) { received, target in
			XCTAssertEqual(target, self.path)
			calls.append(received)
		}
		XCTAssertEqual(calls.count, 1)
		XCTAssertEqual(calls[0][.protectionKey] as? String, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
		XCTAssertEqual(calls[0][.posixPermissions] as? Int, 0o600)
	}

	func testVolumeWithoutProtectionClassesStillGetsThePermissions() throws {
		var calls: [[FileAttributeKey: Any]] = []
		try ProtectedCertificateFiles.applyProtectionAttributes(attributes, at: path) { received, _ in
			calls.append(received)
			if received[.protectionKey] != nil {
				throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
			}
		}
		XCTAssertEqual(calls.count, 2, "retry once, without the protection class")
		XCTAssertNil(calls[1][.protectionKey])
		XCTAssertEqual(calls[1][.posixPermissions] as? Int, 0o600, "permissions must not be dropped with it")
	}

	func testProtectionOnlyAttributeSetNeedsNoSecondCall() throws {
		var calls = 0
		try ProtectedCertificateFiles.applyProtectionAttributes(
			[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], at: path
		) { _, _ in
			calls += 1
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
		}
		XCTAssertEqual(calls, 1, "nothing is left to apply, so do not call again")
	}

	func testAPermissionFailureIsNotRetriedOrSwallowed() {
		var calls = 0
		XCTAssertThrowsError(
			try ProtectedCertificateFiles.applyProtectionAttributes(attributes, at: path) { _, _ in
				calls += 1
				throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
			}
		) { error in
			XCTAssertEqual((error as NSError).code, Int(EACCES))
		}
		XCTAssertEqual(calls, 1, "a real failure must propagate, not be retried without protection")
	}

	func testAFailureApplyingPermissionsAloneStillPropagates() {
		XCTAssertThrowsError(
			try ProtectedCertificateFiles.applyProtectionAttributes(attributes, at: path) { received, _ in
				throw NSError(domain: NSPOSIXErrorDomain,
							  code: received[.protectionKey] != nil ? Int(ENOTSUP) : Int(EACCES))
			}
		) { error in
			XCTAssertEqual((error as NSError).code, Int(EACCES))
		}
	}

	// MARK: - The migration those failures broke

	func testMigrationMovesFilesAndCanBeResumed() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
		let legacy = root.appendingPathComponent("Documents/Certificates")
		let destination = root.appendingPathComponent("Private/Certificates")
		try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
		try Data("first-key".utf8).write(to: legacy.appendingPathComponent("a.p12"))
		try Data("second-key".utf8).write(to: legacy.appendingPathComponent("b.p12"))

		XCTAssertThrowsError(try ProtectedCertificateFiles.migrate(legacy: legacy, destination: destination,
			beforeMove: { source, _ in
				if source.lastPathComponent == "b.p12" { throw CocoaError(.fileWriteOutOfSpace) }
			}))
		XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.p12")), Data("first-key".utf8),
					   "the first file must have moved before the injected failure")
		XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("b.p12")), Data("second-key".utf8))

		try ProtectedCertificateFiles.migrate(legacy: legacy, destination: destination)
		XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("b.p12")), Data("second-key".utf8))
		XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.p12")), Data("first-key".utf8),
					   "resuming must not overwrite what already moved")
		XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
	}

	func testDirectoryFallsBackOnlyWhileMigrationFails() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) } // try? ok: test teardown only
		let legacy = root.appendingPathComponent("legacy")
		let destination = root.appendingPathComponent("private")
		try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
		try Data("fixture-bytes".utf8).write(to: legacy.appendingPathComponent("identity.p12"))

		let chosen = ProtectedCertificateFiles.directory(legacy: legacy, destination: destination,
			migration: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }, report: { _ in })
		XCTAssertEqual(chosen, legacy)

		let retried = ProtectedCertificateFiles.directory(legacy: legacy, destination: destination, report: { _ in })
		XCTAssertEqual(retried, destination, "a successful retry must stop using the legacy directory")
		XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("identity.p12")),
					   Data("fixture-bytes".utf8))
	}
}
