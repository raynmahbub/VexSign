//
//  WatchSnapshotStore.swift
//  VexSign
//
//  The tiny hand-off between the watch app and its complication: the app mirrors
//  every snapshot the iPhone pushes into the watch's app group, and the widget
//  reads it back. Widget extensions cannot open a WCSession, so this file is the
//  only way a face gets numbers.
//
//  Compiled into both the watchOS app and the watch widget extension (see the
//  membership exceptions in project.pbxproj). Foundation only.
//

import Foundation

enum WatchSnapshotStore {
	static let appGroupIdentifier = "group.com.vexsign.watch"
	static let snapshotKey = "VexSign.watch.snapshot"

	static var sharedDefaults: UserDefaults? {
		UserDefaults(suiteName: appGroupIdentifier)
	}

	/// Returns false when the app group is unavailable (a build without the
	/// entitlement), so the caller can log it instead of failing silently.
	@discardableResult
	static func store(_ snapshot: CompanionSnapshot) -> Bool {
		guard let defaults = sharedDefaults,
		      let data = try? JSONEncoder().encode(snapshot)
		else { return false }
		defaults.set(data, forKey: snapshotKey)
		return true
	}

	static func load() -> CompanionSnapshot? {
		guard let defaults = sharedDefaults,
		      let data = defaults.data(forKey: snapshotKey)
		else { return nil }
		return try? JSONDecoder().decode(CompanionSnapshot.self, from: data)
	}

	static func clear() {
		sharedDefaults?.removeObject(forKey: snapshotKey)
	}
}
