//
//  SigningRecordIdentity.swift
//  VexSign
//
//  Which recorded signing runs describe one library copy.
//
//  A signing run has two identities, and they belong to different copies:
//
//    * the copy it was started from - its input, recorded as the task's `subjectID`;
//    * the copy it produced - its output, recorded as `context.artifactID` once it completes.
//
//  Library details looked a run up by `subjectID` alone and called it the "last recorded signing
//  result". For a signed copy that answers the wrong question. The run that produced the copy was
//  never found, because its subject was the copy it started from; and a later re-sign that failed
//  was found and shown as this copy's result, although a failed run never touches the copy it
//  started from. A valid signed copy therefore read "Failed".
//
//  The rule lives here, away from the task center and the views, so it can be tested without
//  either.
//

import Foundation

enum SigningRecordIdentity {
	/// The fields of one signing record that decide which copy it describes.
	struct Entry<Record> {
		let record: Record
		/// The copy the run was started from.
		let sourceID: String?
		/// The copy the run produced. Nil unless the run completed.
		let artifactID: String?
		let updatedAt: Date
		/// The run finished and registered its artifact.
		let completed: Bool

		init(record: Record, sourceID: String?, artifactID: String?, updatedAt: Date, completed: Bool) {
			self.record = record
			self.sourceID = sourceID
			self.artifactID = artifactID
			self.updatedAt = updatedAt
			self.completed = completed
		}
	}

	/// What is on record for one copy.
	struct Selection<Record> {
		/// The run that produced this copy. Nil for an imported copy, and for a signed copy whose
		/// record is gone: history was cleared, or it was signed before runs were recorded.
		var produced: Record?
		/// The newest run started from this copy, whatever its outcome.
		var latestStarted: Record?
		/// `latestStarted`, when it did not complete: still running, failed, cancelled or
		/// interrupted. Such a run left this copy exactly as it was.
		///
		/// Nil when the newest run completed. Its result belongs to the copy it produced, and an
		/// older failure it superseded is no longer the latest thing that happened.
		var unfinishedAttempt: Record?

		init(produced: Record? = nil, latestStarted: Record? = nil, unfinishedAttempt: Record? = nil) {
			self.produced = produced
			self.latestStarted = latestStarted
			self.unfinishedAttempt = unfinishedAttempt
		}
	}

	/// Sorts the recorded signing runs by what they mean for the copy `copyID`.
	///
	/// `entries` are signing runs only, in any order. A missing or empty identifier matches
	/// nothing: two records without one are not records of the same copy.
	static func select<Record>(copyID: String?, from entries: [Entry<Record>]) -> Selection<Record> {
		guard let copyID, !copyID.isEmpty else { return Selection() }

		// Only a completed run has an artifact. The flag is checked as well as the identifier so
		// that a record cannot claim a copy it did not finish producing.
		let produced = _newest(entries.filter { $0.completed && $0.artifactID == copyID })
		let latestStarted = _newest(entries.filter { $0.sourceID == copyID })

		return Selection(
			produced: produced?.record,
			latestStarted: latestStarted?.record,
			unfinishedAttempt: (latestStarted?.completed == false) ? latestStarted?.record : nil
		)
	}

	private static func _newest<Record>(_ entries: [Entry<Record>]) -> Entry<Record>? {
		entries.max { $0.updatedAt < $1.updatedAt }
	}
}
