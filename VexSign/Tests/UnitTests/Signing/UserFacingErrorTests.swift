//
//  UserFacingErrorTests.swift
//  VexSignTests
//
//  What a failure says when it reaches the screen. Three flows forwarded errors that were not
//  `LocalizedError`, so `localizedDescription` produced "The operation couldn't be completed.
//  (VexSign.TweakHandlerError error 0.)" — a message that names a type and an ordinal instead
//  of the file and the next step:
//
//  - tweak injection (signing) for an archive it cannot decompress,
//  - the Apple account session coordinator (login), and
//  - the durable session journal behind it.
//
//  These pin the wording rules rather than the exact sentences: every case answers with
//  something actionable, and none of them echoes a path, a reference, or a raw system error.
//

import XCTest
@testable import VexSign

final class UserFacingErrorTests: XCTestCase {

	/// The sentence Foundation substitutes when nothing conforms to `LocalizedError`:
	/// "The operation couldn't be completed. (VexSign.TweakHandlerError error 0.)"
	///
	/// Matched as a shape, not as the substring "VexSign." — a real message may end a sentence
	/// with the app's name ("…saved by a newer version of VexSign. Update the app…").
	private func isGeneric(_ message: String) -> Bool {
		if message.contains("couldn’t be completed") || message.contains("couldn't be completed") {
			return true
		}
		return message.range(of: #"VexSign\.[A-Za-z]+Error error \d+"#, options: .regularExpression) != nil
	}

	private func assertActionable(
		_ message: String?,
		_ label: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		guard let message, !message.isEmpty else {
			return XCTFail("\(label) has no message", file: file, line: line)
		}
		XCTAssertFalse(isGeneric(message), "\(label) falls back to a system sentence: \(message)", file: file, line: line)
		XCTAssertGreaterThan(message.count, 20, "\(label) is too terse to act on: \(message)", file: file, line: line)
	}

	// MARK: - Tweak injection

	private var tweakErrors: [TweakHandlerError] {
		[
			.unsupportedFileExtension("rar"),
			.unsupportedFileExtension(""),
			.decompressionFailed("truncated header"),
			.decompressionFailed("   "),
			.missingFile("Library/MobileSubstrate/DynamicLibraries/Reveal.dylib"),
			.noAccess,
			.filePickerFixUnavailable,
		]
	}

	func testEveryTweakErrorExplainsItself() {
		for error in tweakErrors {
			assertActionable(error.localizedDescription, "\(error)")
		}
	}

	func testUnsupportedExtensionNamesTheFormatItRefused() {
		let text = TweakHandlerError.unsupportedFileExtension("RAR").errorDescription ?? ""
		XCTAssertTrue(text.lowercased().contains(".rar"), text)
		// The guidance lists what does work, so the user can convert rather than guess.
		XCTAssertTrue(text.contains(".deb"), text)
		XCTAssertTrue(text.contains(".zip"), text)
	}

	func testAnEmptyExtensionStillReads() {
		let text = TweakHandlerError.unsupportedFileExtension("").localizedDescription
		// A path with no extension has nothing to name, so the sentence says "unknown-format"
		// rather than leaving a gap ("cannot unpack  archives").
		XCTAssertTrue(text.lowercased().contains("unknown-format"), text)
		XCTAssertFalse(text.contains("  "), "A missing extension must not leave a double space: \(text)")
	}

	func testDecompressionDetailIsIncludedOnlyWhenPresent() {
		let withDetail = TweakHandlerError.decompressionFailed("truncated header").localizedDescription
		XCTAssertTrue(withDetail.contains("truncated header"), withDetail)
		let withoutDetail = TweakHandlerError.decompressionFailed("   ").localizedDescription
		XCTAssertFalse(withoutDetail.hasSuffix(":"), "A blank detail must not end in a colon: \(withoutDetail)")
	}

	func testInjectionFailureComposesTheInnerReason() {
		let inner = TweakHandlerError.unsupportedFileExtension("7z")
		let failure = TweakInjectionFailure(fileName: "MyTweak.7z", underlying: inner)
		let message = failure.localizedDescription
		XCTAssertTrue(message.contains("MyTweak.7z"), message)
		XCTAssertTrue(message.contains("cannot unpack"), "The inner reason has to survive the wrapper: \(message)")
		XCTAssertFalse(isGeneric(message), message)
	}

	// MARK: - Apple account session (login)

	func testEveryCoordinatorRefusalExplainsItself() {
		let errors: [AppleAccountSessionCoordinatorError] = [
			.cleanupRequired, .invalidSessionMetadata, .resumeRequired, .authenticationInProgress,
		]
		for error in errors {
			assertActionable(error.localizedDescription, "\(error)")
		}
	}

	func testEveryRepositoryFailureExplainsItself() {
		let errors: [AppleAccountSessionRepositoryError] = [
			.unsupportedJournalVersion, .invalidJournal, .sessionAlreadySelected,
			.staleReference, .missingSelectedSession, .signOutIncomplete,
		]
		for error in errors {
			assertActionable(error.localizedDescription, "\(error)")
		}
	}

	func testSessionFailuresNeverEchoStoredMaterial() {
		// A UUID reference, a token or a path would all look like this; the messages are fixed
		// sentences, so the check is that they carry no interpolated content at all.
		let reference = UUID().uuidString
		let messages = [
			AppleAccountSessionCoordinatorError.cleanupRequired.localizedDescription,
			AppleAccountSessionCoordinatorError.invalidSessionMetadata.localizedDescription,
			AppleAccountSessionRepositoryError.staleReference.localizedDescription,
			AppleAccountSessionRepositoryError.invalidJournal.localizedDescription,
		]
		for message in messages {
			XCTAssertFalse(message.contains(reference), message)
			XCTAssertFalse(message.contains("/"), "A session message must not name a path: \(message)")
		}
	}

	func testSignOutFailuresNameTheRetry() {
		// Both messages must point at signing out; the exact wording is free.
		for message in [
			AppleAccountSessionCoordinatorError.cleanupRequired.localizedDescription,
			AppleAccountSessionRepositoryError.signOutIncomplete.localizedDescription,
		] {
			let lowercased = message.lowercased()
			XCTAssertTrue(
				lowercased.contains("sign out") || lowercased.contains("signing out") || lowercased.contains("sign-out"),
				message
			)
		}
	}
}
