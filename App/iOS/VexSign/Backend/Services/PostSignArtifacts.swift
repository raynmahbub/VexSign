//
//  PostSignArtifacts.swift
//  VexSign
//
//  Which library copies remain after a signing run succeeds.
//
//  A run has two copies: the one it was started from (its source) and the one it produced (its
//  output). Each flow used to settle them itself, and two of the rules could be combined into a
//  run that succeeded and left nothing: "Re-sign with last settings" deleted the source as soon
//  as the run succeeded, and Auto Cleanup's "Delete Signed App" then deleted the output because
//  the saved settings did not install it.
//
//  The rule is now in one place:
//
//    * The output is never deleted here. `Decision` has no case that names it and `finish` has
//      no way to remove it, so no setting and no flow can ask for that.
//    * The source is removed only when a rule asks for it, and only after the output is confirmed
//      to be in the library. If that cannot be confirmed, or the deletion does not go through,
//      both copies stay.
//
//  It is kept away from the storage layer, the settings screen and the flows that call it so it
//  can be tested without any of them.
//

import Foundation
import NimbleExtensions

enum PostSignArtifacts {
	// MARK: - Inputs

	/// Which flow ran the sign. It decides only what that flow does with its source.
	///
	/// VexSign updating itself is not one of these. It signs a scratch import of its own update,
	/// packages the result and deletes both entries itself: neither was meant to stay in the
	/// library.
	enum Origin: CaseIterable {
		/// Signing with saved settings and no sheet: "Re-sign with last settings" in a Library
		/// row and in Library details, the Shortcuts actions, auto sign after import and the
		/// web API.
		case savedSettings
		/// The signing sheet.
		case sheet
		/// A batch job.
		case batch
		/// Update All. Its source is the copy it imported a moment before.
		case update
		/// IPA Explorer's "Sign & Install". Its source was edited in place.
		case explorer
	}

	/// The Auto Cleanup switches that concern the source of a run.
	struct Settings: Equatable {
		/// Settings → Auto Cleanup. Neither switch below applies while it is off.
		var autoCleanup: Bool
		/// After Signing → Delete Unsigned App.
		var deleteUnsignedSource: Bool
		/// After Signing → Delete Signed App: remove the signed copy a re-sign was started from.
		var deleteSignedSource: Bool
	}

	/// One run that succeeded.
	struct Run: Equatable {
		var origin: Origin
		/// The copy the run was started from.
		var sourceID: String?
		var sourceIsSigned: Bool
		/// The copy the run produced.
		var outputID: String?
		/// The run's own "Delete After Signing" option. Only the sheet and batch jobs read
		/// it, and only for an unsigned source, as before.
		var runDeletesSource: Bool = false
	}

	// MARK: - Decision

	/// Why a source is removed.
	enum RemovalCause: Equatable {
		/// The flow used the source up: an import that only existed to be signed, or a copy that
		/// was edited in place and no longer matches its signature.
		case consumedByFlow
		/// The run's own "Delete After Signing" option.
		case runOption
		/// An Auto Cleanup switch. The only cause that is reported as a cleanup.
		case cleanupSetting
	}

	/// Why a source is kept.
	enum KeepReason: Equatable {
		/// No rule asks for it to go.
		case notRequested
		/// The source has no identifier, so there is nothing to delete it by. It was most likely
		/// deleted already.
		case sourceUnidentified
		/// Source and output are one copy. Removing "the source" would remove the output.
		case sameCopy
		/// The output is not in the library, or its bundle is not on disk.
		case outputNotConfirmed
	}

	/// What happens to the source. There is no case for the output: it always stays.
	enum Decision: Equatable {
		case keepSource(KeepReason)
		case removeSource(RemovalCause)
	}

	/// What `finish` did.
	struct Outcome: Equatable {
		let decision: Decision
		/// True only when the library reported the source as deleted. A source that is in use by
		/// another operation is not deleted, and then both copies stay.
		let sourceRemoved: Bool
	}

	/// Whether a rule asks for the source of `run` to go, and which one.
	///
	/// This is intent only. It says nothing about whether removing the source is safe: see
	/// `decision(for:settings:outputIsInLibrary:)`.
	static func requestedRemoval(_ run: Run, settings: Settings) -> RemovalCause? {
		switch (run.origin, run.sourceIsSigned) {
		case (.explorer, _):
			// The explorer writes straight into the copy it has open, so after a sign that copy
			// is neither the original nor validly signed. The output replaces it.
			return .consumedByFlow

		case (.savedSettings, false), (.update, false):
			// An import that was signed without the sheet only existed to feed the signer.
			return .consumedByFlow

		case (.sheet, false), (.batch, false):
			if run.runDeletesSource { return .runOption }
			return settings.autoCleanup && settings.deleteUnsignedSource ? .cleanupSetting : nil

		case (.savedSettings, true), (.sheet, true), (.batch, true), (.update, true):
			// A signed copy is something the user can install. A re-sign removes the one it was
			// started from only when the user has asked for that.
			return settings.autoCleanup && settings.deleteSignedSource ? .cleanupSetting : nil
		}
	}

	/// Decides what happens to the source of `run`.
	///
	/// `outputIsInLibrary` is given the output's identifier and answers whether the library has
	/// a signed row for it with its bundle on disk. It is asked only when a rule wants the source
	/// removed, and it is asked at the moment of the decision: the run reported success some
	/// time before the flow gets here, and the output may have been deleted in between.
	static func decision(
		for run: Run,
		settings: Settings,
		outputIsInLibrary: (String) -> Bool
	) -> Decision {
		guard let cause = requestedRemoval(run, settings: settings) else {
			return .keepSource(.notRequested)
		}
		guard let sourceID = run.sourceID, !sourceID.isEmpty else {
			return .keepSource(.sourceUnidentified)
		}
		guard let outputID = run.outputID, !outputID.isEmpty else {
			return .keepSource(.outputNotConfirmed)
		}
		guard sourceID != outputID else {
			return .keepSource(.sameCopy)
		}
		guard outputIsInLibrary(outputID) else {
			return .keepSource(.outputNotConfirmed)
		}
		return .removeSource(cause)
	}

	// MARK: - Execution

	/// Settles the copies of a run that succeeded.
	///
	/// `removeSource` deletes the source and answers whether the library deleted it. It is the
	/// only thing here that deletes, and it takes no identifier: the caller binds it to the
	/// source, so this function cannot be made to delete anything else.
	static func finish(
		_ run: Run,
		settings: Settings,
		outputIsInLibrary: (String) -> Bool,
		removeSource: (RemovalCause) -> Bool
	) -> Outcome {
		let decision = Self.decision(for: run, settings: settings, outputIsInLibrary: outputIsInLibrary)
		guard case .removeSource(let cause) = decision else {
			return Outcome(decision: decision, sourceRemoved: false)
		}
		return Outcome(decision: decision, sourceRemoved: removeSource(cause))
	}

	// MARK: - Wording

	/// The line the repeat-signing review shows about the signed copy the run is started from.
	///
	/// Built from the rule the run follows, so the review cannot say one thing while the run
	/// does another.
	static func repeatSigningNotice(settings: Settings) -> String {
		let run = Run(origin: .savedSettings, sourceID: nil, sourceIsSigned: true, outputID: nil)
		if requestedRemoval(run, settings: settings) != nil {
			return .localized("On success, the new signed copy is added to your library and this copy is removed, because Delete Signed App is on in Settings → Auto Cleanup. Your installation settings apply to the new copy.")
		}
		return .localized("On success, the new signed copy is added to your library and this copy stays. To have this copy removed instead, turn on Delete Signed App in Settings → Auto Cleanup. Your installation settings apply to the new copy.")
	}
}
