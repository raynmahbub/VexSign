//
//  BackupRestorePlan.swift
//  VexSign
//
//  Whether one entry inside a backup container may be written back.
//
//  A restore writes into the app's own directories and Core Data store, so the *order* of these
//  checks is the safety property rather than an implementation detail:
//
//   1. an item the store already tracks wins — the user's existing copy is never replaced, so
//      restoring the same archive twice adds nothing the second time;
//   2. an entry whose payload is missing from the container is skipped. It is one damaged entry,
//      not a reason to abort the entries after it;
//   3. a directory that exists with no record behind it is never replaced. That is what an
//      interrupted earlier import looks like, and VexSign cannot tell what it holds;
//   4. only then is the entry restored.
//
//  The rules were inline `if … continue` chains inside `BackupManager.restore`, which is where
//  they could not be asserted: the whole restore path needs the real container, Core Data and a
//  decrypted archive. This is the part of it that can be decided from four booleans.
//

import Foundation

enum BackupRestorePlan {
	enum Decision: Equatable {
		/// Copy the payload in and register it.
		case restore
		/// A record for this item is already in the store; its files are left untouched.
		case skipAlreadyPresent
		/// The container does not hold this entry's files.
		case skipMissingPayload
		/// A directory is in the way that no record points at.
		case skipDestinationOccupied

		var shouldRestore: Bool { self == .restore }
	}

	static func decision(
		alreadyTracked: Bool,
		payloadPresent: Bool,
		destinationOccupied: Bool
	) -> Decision {
		if alreadyTracked { return .skipAlreadyPresent }
		if !payloadPresent { return .skipMissingPayload }
		if destinationOccupied { return .skipDestinationOccupied }
		return .restore
	}
}
