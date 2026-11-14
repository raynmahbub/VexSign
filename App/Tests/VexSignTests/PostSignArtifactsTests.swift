//
//  PostSignArtifactsTests.swift
//  VexSignTests
//
//  Which library copies remain after a signing run succeeds.
//
//  A successful re-sign could leave no copy at all: "Re-sign with last settings" deleted the copy
//  it was started from as soon as the run succeeded, and Auto Cleanup's "Delete Signed App" then
//  deleted the new copy because the saved settings did not install it. The signing sheet deleted
//  its own output the same way.
//
//  These tests run the rule against a small in-memory library for every combination of the
//  settings that used to matter - Delete Signed App, Auto Cleanup, install after signing, and a
//  signed or unsigned source - once for each flow that signs.
//

import Foundation
import NimbleExtensions
import XCTest
@testable import VexSign

final class PostSignArtifactsTests: XCTestCase {
	// MARK: - A library to run against

	/// The two calls the rule is given, backed by sets instead of Core Data and the file system.
	private final class Library {
		var signed: Set<String> = []
		var imported: Set<String> = []
		/// Signed rows whose bundle is not on disk.
		var missingBundles: Set<String> = []
		/// Copies another operation is using. Deleting one is refused.
		var busy: Set<String> = []

		private(set) var confirmations: [String] = []
		private(set) var deletionAttempts: [String] = []
		private(set) var causes: [PostSignArtifacts.RemovalCause] = []

		var copies: Set<String> { signed.union(imported) }

		func holdsSignedCopy(_ uuid: String) -> Bool {
			confirmations.append(uuid)
			return signed.contains(uuid) && !missingBundles.contains(uuid)
		}

		func delete(_ uuid: String?, cause: PostSignArtifacts.RemovalCause) -> Bool {
			causes.append(cause)
			guard let uuid else { return false }
			deletionAttempts.append(uuid)
			guard !busy.contains(uuid), copies.contains(uuid) else { return false }
			signed.remove(uuid)
			imported.remove(uuid)
			return true
		}
	}

	private static let source = "source-copy"
	private static let output = "output-copy"

	/// A library as a successful run leaves it: the source where it was, the output registered.
	private func libraryAfterSuccess(sourceIsSigned: Bool) -> Library {
		let library = Library()
		if sourceIsSigned {
			library.signed.insert(Self.source)
		} else {
			library.imported.insert(Self.source)
		}
		library.signed.insert(Self.output)
		return library
	}

	private func successfulRun(
		_ origin: PostSignArtifacts.Origin,
		sourceIsSigned: Bool,
		runDeletesSource: Bool = false
	) -> PostSignArtifacts.Run {
		PostSignArtifacts.Run(
			origin: origin,
			sourceID: Self.source,
			sourceIsSigned: sourceIsSigned,
			outputID: Self.output,
			runDeletesSource: runDeletesSource
		)
	}

	/// Runs the rule the way `CleanupManager.finishSign` does: the delete is bound to the source.
	@discardableResult
	private func finish(
		_ run: PostSignArtifacts.Run,
		settings: PostSignArtifacts.Settings,
		in library: Library
	) -> PostSignArtifacts.Outcome {
		PostSignArtifacts.finish(
			run,
			settings: settings,
			outputIsInLibrary: { library.holdsSignedCopy($0) },
			removeSource: { library.delete(run.sourceID, cause: $0) }
		)
	}

	private static let everythingOn = PostSignArtifacts.Settings(
		autoCleanup: true,
		deleteUnsignedSource: true,
		deleteSignedSource: true
	)

	private static let everythingOff = PostSignArtifacts.Settings(
		autoCleanup: false,
		deleteUnsignedSource: false,
		deleteSignedSource: false
	)

	// MARK: - The sixteen combinations, per flow

	/// One row per combination. Four switches, then whether the source is removed:
	///
	///     D  Auto Cleanup → Delete Signed App
	///     C  Auto Cleanup (the master switch)
	///     I  install after signing
	///     S  the source is a signed copy
	///     →  1 when the source is removed, 0 when it stays
	///
	/// "Delete Unsigned App" and the run's own "Delete After Signing" are off throughout;
	/// they have their own tests below. The signed copy the run produced stays in every row.
	private static let expected: [PostSignArtifacts.Origin: [String]] = [
		// Saved settings: an import is used up; a signed copy goes only on request.
		.savedSettings: [
			"0000:1", "0001:0", "0010:1", "0011:0",
			"0100:1", "0101:0", "0110:1", "0111:0",
			"1000:1", "1001:0", "1010:1", "1011:0",
			"1100:1", "1101:1", "1110:1", "1111:1",
		],
		// The sheet: nothing goes unless asked.
		.sheet: [
			"0000:0", "0001:0", "0010:0", "0011:0",
			"0100:0", "0101:0", "0110:0", "0111:0",
			"1000:0", "1001:0", "1010:0", "1011:0",
			"1100:0", "1101:1", "1110:0", "1111:1",
		],
		// A batch job: the same as the sheet.
		.batch: [
			"0000:0", "0001:0", "0010:0", "0011:0",
			"0100:0", "0101:0", "0110:0", "0111:0",
			"1000:0", "1001:0", "1010:0", "1011:0",
			"1100:0", "1101:1", "1110:0", "1111:1",
		],
		// Update All: the copy it imported is used up.
		.update: [
			"0000:1", "0001:0", "0010:1", "0011:0",
			"0100:1", "0101:0", "0110:1", "0111:0",
			"1000:1", "1001:0", "1010:1", "1011:0",
			"1100:1", "1101:1", "1110:1", "1111:1",
		],
		// IPA Explorer: the copy it edited in place is replaced.
		.explorer: [
			"0000:1", "0001:1", "0010:1", "0011:1",
			"0100:1", "0101:1", "0110:1", "0111:1",
			"1000:1", "1001:1", "1010:1", "1011:1",
			"1100:1", "1101:1", "1110:1", "1111:1",
		],
	]

	private struct Combination: Hashable {
		let deleteSignedApp: Bool
		let autoCleanup: Bool
		let installsAfterSigning: Bool
		let sourceIsSigned: Bool
		let sourceIsRemoved: Bool

		init?(_ row: String) {
			let flags = row.compactMap { character -> Bool? in
				switch character {
				case "0": return false
				case "1": return true
				default: return nil
				}
			}
			guard row.count == 6, flags.count == 5 else { return nil }
			deleteSignedApp = flags[0]
			autoCleanup = flags[1]
			installsAfterSigning = flags[2]
			sourceIsSigned = flags[3]
			sourceIsRemoved = flags[4]
		}

		var switches: String {
			[deleteSignedApp, autoCleanup, installsAfterSigning, sourceIsSigned]
				.map { $0 ? "1" : "0" }
				.joined()
		}
	}

	func testEveryFlowHasAllSixteenCombinations() throws {
		XCTAssertEqual(Set(Self.expected.keys), Set(PostSignArtifacts.Origin.allCases), "Every flow that signs has a table")

		let all = Set((0..<16).map { number in
			String(repeating: "0", count: 4 - String(number, radix: 2).count) + String(number, radix: 2)
		})
		XCTAssertEqual(all.count, 16)

		for (origin, rows) in Self.expected {
			let combinations = try rows.map { try XCTUnwrap(Combination($0), "Unreadable row \($0)") }
			XCTAssertEqual(combinations.count, 16, "\(origin)")
			XCTAssertEqual(Set(combinations.map(\.switches)), all, "\(origin): each combination exactly once")
		}
	}

	func testEveryCombinationKeepsTheSignedCopyAndSettlesTheSourceAsListed() throws {
		for origin in PostSignArtifacts.Origin.allCases {
			for row in try XCTUnwrap(Self.expected[origin]) {
				let combination = try XCTUnwrap(Combination(row))
				let label = "\(origin) \(row)"

				let library = libraryAfterSuccess(sourceIsSigned: combination.sourceIsSigned)
				let outcome = finish(
					successfulRun(origin, sourceIsSigned: combination.sourceIsSigned),
					settings: PostSignArtifacts.Settings(
						autoCleanup: combination.autoCleanup,
						deleteUnsignedSource: false,
						deleteSignedSource: combination.deleteSignedApp
					),
					in: library
				)

				XCTAssertEqual(outcome.sourceRemoved, combination.sourceIsRemoved, label)
				XCTAssertEqual(library.copies.contains(Self.source), !combination.sourceIsRemoved, label)

				// The point of all of it: whatever the settings, the run leaves its result.
				XCTAssertTrue(library.signed.contains(Self.output), "\(label): the signed copy is gone")
				XCTAssertFalse(library.copies.isEmpty, "\(label): the run left no copy at all")
				XCTAssertFalse(library.deletionAttempts.contains(Self.output), "\(label): the signed copy was offered for deletion")

				if combination.installsAfterSigning {
					// The flow hands the signed copy to the installer right after this.
					XCTAssertTrue(library.holdsSignedCopy(Self.output), "\(label): the installer was handed a copy that is gone")
				}
			}
		}
	}

	/// The report this change answers, spelled out: Delete Signed App and Auto Cleanup on, saved
	/// settings that do not install. Both copies used to be deleted.
	func testAReSignThatDoesNotInstallNoLongerLeavesNoCopy() {
		for sourceIsSigned in [true, false] {
			let library = libraryAfterSuccess(sourceIsSigned: sourceIsSigned)

			let outcome = finish(
				successfulRun(.savedSettings, sourceIsSigned: sourceIsSigned),
				settings: PostSignArtifacts.Settings(autoCleanup: true, deleteUnsignedSource: false, deleteSignedSource: true),
				in: library
			)

			XCTAssertTrue(outcome.sourceRemoved, "The source goes, as the settings ask")
			XCTAssertEqual(library.copies, [Self.output], "The new signed copy is what remains")
		}
	}

	/// Install after signing is not an input of the rule at all. Before, it was the only thing
	/// between "Delete Signed App" and the run's own output.
	func testEveryOtherSettingStillLeavesTheSignedCopy() {
		for origin in PostSignArtifacts.Origin.allCases {
			for autoCleanup in [true, false] {
				for deleteUnsigned in [true, false] {
					for deleteSigned in [true, false] {
						for sourceIsSigned in [true, false] {
							for runDeletesSource in [true, false] {
								let library = libraryAfterSuccess(sourceIsSigned: sourceIsSigned)
								finish(
									successfulRun(origin, sourceIsSigned: sourceIsSigned, runDeletesSource: runDeletesSource),
									settings: PostSignArtifacts.Settings(
										autoCleanup: autoCleanup,
										deleteUnsignedSource: deleteUnsigned,
										deleteSignedSource: deleteSigned
									),
									in: library
								)

								XCTAssertTrue(library.signed.contains(Self.output), "\(origin)")
								XCTAssertTrue(library.deletionAttempts.allSatisfy { $0 == Self.source }, "\(origin): only the source is ever deleted")
							}
						}
					}
				}
			}
		}
	}

	// MARK: - A run that did not produce a copy

	/// A failed or cancelled run registers nothing, and the pipeline removes whatever bundle it
	/// had moved. No flow calls the rule for such a run; if one ever did, this is what it gets.
	func testARunThatFailedOrWasCancelledDeletesNothing() {
		for origin in PostSignArtifacts.Origin.allCases {
			for sourceIsSigned in [true, false] {
				// Stopped before it had an output at all, and stopped after it had picked an
				// identifier for one: either way there is no row for it.
				for outputID in [nil, Self.output] as [String?] {
					let library = Library()
					if sourceIsSigned { library.signed.insert(Self.source) } else { library.imported.insert(Self.source) }

					var run = successfulRun(origin, sourceIsSigned: sourceIsSigned, runDeletesSource: true)
					run.outputID = outputID
					let outcome = finish(run, settings: Self.everythingOn, in: library)

					XCTAssertEqual(outcome.decision, .keepSource(.outputNotConfirmed), "\(origin)")
					XCTAssertFalse(outcome.sourceRemoved)
					XCTAssertEqual(library.copies, [Self.source], "\(origin): the source is all there is, and it stays")
					XCTAssertEqual(library.deletionAttempts, [], "\(origin): nothing was even attempted")
				}
			}
		}
	}

	// MARK: - The output has to be confirmed first

	func testAnOutputWithoutARowBlocksSourceDeletion() {
		for origin in PostSignArtifacts.Origin.allCases {
			let library = libraryAfterSuccess(sourceIsSigned: true)
			// Deleted by the user, or by anything else, after the run reported success.
			library.signed.remove(Self.output)

			let outcome = finish(successfulRun(origin, sourceIsSigned: true), settings: Self.everythingOn, in: library)

			XCTAssertEqual(outcome.decision, .keepSource(.outputNotConfirmed), "\(origin)")
			XCTAssertEqual(library.copies, [Self.source], "\(origin): the last copy must not go")
			XCTAssertEqual(library.deletionAttempts, [])
		}
	}

	func testAnOutputWhoseBundleIsMissingBlocksSourceDeletion() {
		for origin in PostSignArtifacts.Origin.allCases {
			let library = libraryAfterSuccess(sourceIsSigned: false)
			library.missingBundles.insert(Self.output)

			let outcome = finish(successfulRun(origin, sourceIsSigned: false, runDeletesSource: true), settings: Self.everythingOn, in: library)

			XCTAssertEqual(outcome.decision, .keepSource(.outputNotConfirmed), "\(origin)")
			XCTAssertTrue(library.imported.contains(Self.source), "\(origin): a row without a bundle is not a copy to rely on")
			XCTAssertEqual(library.deletionAttempts, [])
		}
	}

	func testTheOutputIsConfirmedBeforeTheSourceIsDeleted() {
		var events: [String] = []
		let outcome = PostSignArtifacts.finish(
			successfulRun(.savedSettings, sourceIsSigned: false),
			settings: Self.everythingOff,
			outputIsInLibrary: { events.append("confirm \($0)"); return true },
			removeSource: { _ in events.append("delete source"); return true }
		)

		XCTAssertEqual(events, ["confirm \(Self.output)", "delete source"])
		XCTAssertTrue(outcome.sourceRemoved)
	}

	/// A run with no identifier for its output has nothing to confirm. It is not left to the
	/// library to say so: a lookup that matched on a missing identifier would be the one answer
	/// that lets the source go.
	func testAnOutputWithoutAnIdentifierIsNeverConfirmed() {
		for origin in PostSignArtifacts.Origin.allCases {
			for missing in [nil, ""] as [String?] {
				var run = successfulRun(origin, sourceIsSigned: true, runDeletesSource: true)
				run.outputID = missing

				var asked: [String] = []
				var deletions = 0
				let outcome = PostSignArtifacts.finish(
					run,
					settings: Self.everythingOn,
					outputIsInLibrary: { asked.append($0); return true },
					removeSource: { _ in deletions += 1; return true }
				)

				XCTAssertEqual(outcome.decision, .keepSource(.outputNotConfirmed), "\(origin)")
				XCTAssertFalse(outcome.sourceRemoved, "\(origin)")
				XCTAssertEqual(asked, [], "\(origin): there is no identifier to ask about")
				XCTAssertEqual(deletions, 0, "\(origin)")
			}
		}
	}

	func testTheLibraryIsNotAskedWhenNothingWantsTheSourceRemoved() {
		let library = libraryAfterSuccess(sourceIsSigned: true)

		let outcome = finish(successfulRun(.savedSettings, sourceIsSigned: true), settings: Self.everythingOff, in: library)

		XCTAssertEqual(outcome.decision, .keepSource(.notRequested))
		XCTAssertEqual(library.confirmations, [], "No question, no fetch")
		XCTAssertEqual(library.deletionAttempts, [])
	}

	// MARK: - Source and output are one copy

	func testASourceThatIsAlsoTheOutputIsNeverDeleted() {
		for origin in PostSignArtifacts.Origin.allCases {
			let library = Library()
			library.signed.insert(Self.output)

			var run = successfulRun(origin, sourceIsSigned: true, runDeletesSource: true)
			run.sourceID = Self.output
			let outcome = finish(run, settings: Self.everythingOn, in: library)

			XCTAssertEqual(outcome.decision, .keepSource(.sameCopy), "\(origin)")
			XCTAssertFalse(outcome.sourceRemoved)
			XCTAssertEqual(library.signed, [Self.output], "\(origin): deleting \"the source\" would have deleted the result")
			XCTAssertEqual(library.deletionAttempts, [])
		}
	}

	func testASourceWithoutAnIdentifierIsLeftAlone() {
		for missing in [nil, ""] as [String?] {
			let library = libraryAfterSuccess(sourceIsSigned: false)

			var run = successfulRun(.savedSettings, sourceIsSigned: false)
			run.sourceID = missing
			let outcome = finish(run, settings: Self.everythingOn, in: library)

			XCTAssertEqual(outcome.decision, .keepSource(.sourceUnidentified))
			XCTAssertEqual(library.deletionAttempts, [])
			XCTAssertEqual(library.copies, [Self.source, Self.output])
		}
	}

	// MARK: - A deletion that does not go through

	func testASourceThatIsInUseStaysAndIsNotReportedAsRemoved() {
		for origin in PostSignArtifacts.Origin.allCases {
			let library = libraryAfterSuccess(sourceIsSigned: true)
			library.busy.insert(Self.source)

			let outcome = finish(successfulRun(origin, sourceIsSigned: true), settings: Self.everythingOn, in: library)

			XCTAssertEqual(library.deletionAttempts, [Self.source], "\(origin): it was asked for")
			XCTAssertFalse(outcome.sourceRemoved, "\(origin): and refused, so it is not reported as removed")
			XCTAssertEqual(library.copies, [Self.source, Self.output], "\(origin): both copies stay")
		}
	}

	// MARK: - What asks for the source to go

	func testTheMasterSwitchTurnsBothCleanupSwitchesOff() {
		let masterOff = PostSignArtifacts.Settings(autoCleanup: false, deleteUnsignedSource: true, deleteSignedSource: true)

		for origin in [PostSignArtifacts.Origin.sheet, .batch] {
			for sourceIsSigned in [true, false] {
				let library = libraryAfterSuccess(sourceIsSigned: sourceIsSigned)
				let outcome = finish(successfulRun(origin, sourceIsSigned: sourceIsSigned), settings: masterOff, in: library)

				XCTAssertEqual(outcome.decision, .keepSource(.notRequested), "\(origin)")
				XCTAssertEqual(library.copies, [Self.source, Self.output])
			}
		}

		// A re-sign from saved settings follows the same switch.
		let library = libraryAfterSuccess(sourceIsSigned: true)
		finish(successfulRun(.savedSettings, sourceIsSigned: true), settings: masterOff, in: library)
		XCTAssertEqual(library.copies, [Self.source, Self.output])
	}

	func testEachCleanupSwitchOnlyReachesItsOwnKindOfSource() {
		let unsignedOnly = PostSignArtifacts.Settings(autoCleanup: true, deleteUnsignedSource: true, deleteSignedSource: false)
		let signedOnly = PostSignArtifacts.Settings(autoCleanup: true, deleteUnsignedSource: false, deleteSignedSource: true)

		for origin in [PostSignArtifacts.Origin.sheet, .batch] {
			XCTAssertEqual(PostSignArtifacts.requestedRemoval(successfulRun(origin, sourceIsSigned: false), settings: unsignedOnly), .cleanupSetting)
			XCTAssertNil(PostSignArtifacts.requestedRemoval(successfulRun(origin, sourceIsSigned: true), settings: unsignedOnly))

			XCTAssertEqual(PostSignArtifacts.requestedRemoval(successfulRun(origin, sourceIsSigned: true), settings: signedOnly), .cleanupSetting)
			XCTAssertNil(PostSignArtifacts.requestedRemoval(successfulRun(origin, sourceIsSigned: false), settings: signedOnly))
		}
	}

	func testTheRunsOwnOptionRemovesAnUnsignedSourceOnlyInTheSheetAndInABatch() {
		for origin in [PostSignArtifacts.Origin.sheet, .batch] {
			XCTAssertEqual(
				PostSignArtifacts.requestedRemoval(successfulRun(origin, sourceIsSigned: false, runDeletesSource: true), settings: Self.everythingOff),
				.runOption,
				"\(origin): the option needs no Auto Cleanup"
			)
			XCTAssertNil(
				PostSignArtifacts.requestedRemoval(successfulRun(origin, sourceIsSigned: true, runDeletesSource: true), settings: Self.everythingOff),
				"\(origin): the option never reached a signed source, and still does not"
			)
		}

		// Saved settings carry the option too, but a signed source there follows Auto Cleanup alone.
		XCTAssertNil(PostSignArtifacts.requestedRemoval(
			successfulRun(.savedSettings, sourceIsSigned: true, runDeletesSource: true),
			settings: Self.everythingOff
		))
	}

	/// Only an Auto Cleanup deletion is reported as a cleanup, so the cause has to be right.
	func testTheCauseSaysWhoAskedForTheSourceToGo() {
		func cause(_ origin: PostSignArtifacts.Origin, signed: Bool) -> PostSignArtifacts.RemovalCause? {
			PostSignArtifacts.requestedRemoval(successfulRun(origin, sourceIsSigned: signed), settings: Self.everythingOn)
		}

		XCTAssertEqual(cause(.savedSettings, signed: false), .consumedByFlow)
		XCTAssertEqual(cause(.update, signed: false), .consumedByFlow)
		XCTAssertEqual(cause(.explorer, signed: false), .consumedByFlow)
		XCTAssertEqual(cause(.explorer, signed: true), .consumedByFlow)

		XCTAssertEqual(cause(.savedSettings, signed: true), .cleanupSetting)
		XCTAssertEqual(cause(.sheet, signed: true), .cleanupSetting)
		XCTAssertEqual(cause(.sheet, signed: false), .cleanupSetting)
		XCTAssertEqual(cause(.batch, signed: true), .cleanupSetting)
		XCTAssertEqual(cause(.batch, signed: false), .cleanupSetting)
		XCTAssertEqual(cause(.update, signed: true), .cleanupSetting)

		// The cause that reaches the deletion is the one that was decided.
		let library = libraryAfterSuccess(sourceIsSigned: true)
		finish(successfulRun(.sheet, sourceIsSigned: true), settings: Self.everythingOn, in: library)
		XCTAssertEqual(library.causes, [.cleanupSetting])
	}

	// MARK: - What the review says

	func testTheReviewSaysWhatTheRunWillDoWithTheCopyItStartsFrom() {
		// Compared with the catalogue entries, not with English words, so the test holds in any
		// language and still notices the two lines being swapped.
		let keeps = String.localized("On success, the new signed copy is added to your library and this copy stays. To have this copy removed instead, turn on Delete Signed App in Settings → Auto Cleanup. Your installation settings apply to the new copy.")
		let removes = String.localized("On success, the new signed copy is added to your library and this copy is removed, because Delete Signed App is on in Settings → Auto Cleanup. Your installation settings apply to the new copy.")
		XCTAssertNotEqual(keeps, removes)
		XCTAssertEqual(PostSignArtifacts.repeatSigningNotice(settings: Self.everythingOff), keeps)
		XCTAssertEqual(PostSignArtifacts.repeatSigningNotice(settings: Self.everythingOn), removes)

		for autoCleanup in [true, false] {
			for deleteUnsigned in [true, false] {
				for deleteSigned in [true, false] {
					let settings = PostSignArtifacts.Settings(
						autoCleanup: autoCleanup,
						deleteUnsignedSource: deleteUnsigned,
						deleteSignedSource: deleteSigned
					)
					let runRemovesIt = PostSignArtifacts.requestedRemoval(
						successfulRun(.savedSettings, sourceIsSigned: true),
						settings: settings
					) != nil

					XCTAssertEqual(runRemovesIt, autoCleanup && deleteSigned)
					XCTAssertEqual(
						PostSignArtifacts.repeatSigningNotice(settings: settings),
						runRemovesIt ? removes : keeps,
						"The review and the run read the same rule"
					)
				}
			}
		}
	}
}
