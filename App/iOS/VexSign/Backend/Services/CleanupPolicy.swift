//
//  CleanupPolicy.swift
//  VexSign
//
//  What a cleanup pass may remove: which storage areas it clears while an operation is still
//  running, and which signed copies the "Keep only the newest signed copy" rule gives up.
//
//  Both are decisions about files the user may still want, so they are kept here as plain rules
//  that can be tested without the storage layer. `CleanupManager` and `StorageRules` carry them
//  out.
//

import Foundation

// MARK: - Storage areas

enum CleanupPassPolicy {
	/// Storage areas a pass leaves alone while an operation is running.
	///
	/// The temporary directory holds the work directory of every sign in flight and the archive
	/// a running install is handing to iOS. Clearing it because one operation had finished took
	/// those files away from every other operation, which then stopped part-way.
	///
	/// A leftover is a folder in the library that no row accounts for. A copy that is being
	/// produced is exactly that between the moment its bundle is moved into the library and the
	/// moment its row is committed, so a pass that removed leftovers in that window deleted a
	/// bundle that was about to be registered.
	static let deferredWhileOperating: [StorageCategory] = [.temporary, .leftovers]

	struct Plan: Equatable {
		/// Cleared now, in the order they were asked for.
		var clear: [StorageCategory]
		/// Asked for, and left for a later pass because something is running.
		var deferred: [StorageCategory]
	}

	/// Splits what was asked for into what is cleared now and what waits.
	///
	/// Nothing is ever added: a category that was not asked for is in neither list. What waits is
	/// picked up by the next pass that finds nothing running, and by the next launch.
	static func plan(_ requested: [StorageCategory], operationsActive: Bool) -> Plan {
		guard operationsActive else {
			return Plan(clear: requested, deferred: [])
		}
		return Plan(
			clear: requested.filter { !deferredWhileOperating.contains($0) },
			deferred: requested.filter { deferredWhileOperating.contains($0) }
		)
	}
}

// MARK: - Duplicate signed copies

/// The "Keep only the newest signed copy" rule.
enum SignedCopyRetention {
	/// What the rule reads of one signed copy.
	struct Copy: Equatable {
		let uuid: String
		/// What makes two copies the same app: the bundle identifier, or the name without one.
		let app: String
		let version: String?
		/// When the copy was added to the library.
		let date: Date?
	}

	/// The copies the rule removes: for every app with several signed copies, all but one.
	///
	/// The copy that is kept has the highest version. Among copies of the same version it is the
	/// one added last. A re-sign produces a copy with the same version as the one it was started
	/// from, and the rule used to compare versions only, which left the choice between those two
	/// to the order the rows happened to be fetched in. It could keep the older copy and delete
	/// the one that had just been signed.
	///
	/// The result is in a stable order, so the same library always gives the same answer.
	static func surplus(among copies: [Copy]) -> [Copy] {
		var seen = Set<String>()
		let distinct = copies.filter { seen.insert($0.uuid).inserted }
		let groups = Dictionary(grouping: distinct, by: \.app)

		return groups.keys.sorted().flatMap { app -> [Copy] in
			let ranked = (groups[app] ?? []).sorted { isKept($0, before: $1) }
			return Array(ranked.dropFirst())
		}
	}

	/// True when `first` is the copy to keep out of the two.
	static func isKept(_ first: Copy, before second: Copy) -> Bool {
		let firstVersion = versionKey(first.version)
		let secondVersion = versionKey(second.version)
		if firstVersion != secondVersion {
			return secondVersion.lexicographicallyPrecedes(firstVersion)
		}

		let firstDate = first.date ?? .distantPast
		let secondDate = second.date ?? .distantPast
		if firstDate != secondDate {
			return firstDate > secondDate
		}

		// Same version, same moment: any fixed order will do, as long as it is always the same.
		return first.uuid < second.uuid
	}

	/// The numeric components of a version, without trailing zeros, so "1.2" and "1.2.0" are the
	/// same version and the date decides between them. A component that is not a number is
	/// skipped, as before; a copy with no readable version sorts below every other.
	static func versionKey(_ version: String?) -> [Int] {
		guard let version else { return [] }
		var parts = version.split(separator: ".").compactMap { Int($0) }
		while parts.last == 0 { parts.removeLast() }
		return parts
	}
}
