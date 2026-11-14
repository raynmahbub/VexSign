//
//  SourcePreferences.swift
//  VexSign
//
//  Local repository ordering, trust, visibility, and refresh metadata.
//  Trust is deliberately user-assigned: a green badge never claims that VexSign
//  cryptographically verified a repository publisher.
//

import Foundation

enum SourcePreferences {
	private static let pinnedKey = "VexSign.sources.pinned"
	private static let priorityKey = "VexSign.sources.priority"
	private static let trustedKey = "VexSign.sources.trusted"
	private static let lastFetchKey = "VexSign.sources.lastFetch"
	private static let lastErrorKey = "VexSign.sources.lastError"
	private static let hideDuplicatesKey = "VexSign.sources.hideDuplicates"
	private static let lastSuccessKey = "VexSign.sources.lastSuccess"
	private static let failureCountKey = "VexSign.sources.failureCount"
	private static let rateLimitUntilKey = "VexSign.sources.rateLimitUntil"
	private static let autoUpdatesKey = "VexSign.sources.autoUpdates"

	/// Health of one repository, as consumed by the Source Health dashboard.
	struct Health {
		let id: String
		var lastAttempt: Date?
		var lastSuccess: Date?
		var lastError: String?
		/// Consecutive failed refreshes (reset by any success).
		var consecutiveFailures: Int = 0
		/// When the server answered HTTP 429 — refreshes are skipped until then.
		var rateLimitedUntil: Date?

		var isRateLimited: Bool {
			guard let until = rateLimitedUntil else { return false }
			return until > Date()
		}

		/// Suggested delay before the next automatic retry (exponential backoff).
		var suggestedRetryDelay: TimeInterval {
			switch consecutiveFailures {
			case 0: return 0
			case 1: return 60
			case 2: return 5 * 60
			case 3: return 15 * 60
			default: return 60 * 60
			}
		}

		var nextRetryDate: Date? {
			guard let last = lastAttempt, consecutiveFailures > 0 else { return nil }
			return last.addingTimeInterval(suggestedRetryDelay)
		}
	}

	static var hideDuplicates: Bool {
		get { UserDefaults.standard.bool(forKey: hideDuplicatesKey) }
		set { UserDefaults.standard.set(newValue, forKey: hideDuplicatesKey) }
	}

	static func isPinned(_ id: String) -> Bool {
		pinned.contains(id)
	}

	/// Source-level opt-out for scheduled signing. Missing values preserve the
	/// existing behavior and mean the source is eligible for automatic updates.
	static func autoUpdatesEnabled(for id: String) -> Bool {
		let values: [String: Bool] = _dictionary(autoUpdatesKey)
		return values[id] ?? true
	}

	static func setAutoUpdatesEnabled(_ enabled: Bool, for id: String) {
		var values: [String: Bool] = _dictionary(autoUpdatesKey)
		if enabled {
			values.removeValue(forKey: id)
		} else {
			values[id] = false
		}
		UserDefaults.standard.set(values, forKey: autoUpdatesKey)
	}

	static func setPinned(_ id: String, pinned isPinned: Bool) {
		var set = pinned
		if isPinned { set.insert(id) } else { set.remove(id) }
		UserDefaults.standard.set(Array(set), forKey: pinnedKey)
	}

	// MARK: - Repository priority

	/// Lower values win when two repositories publish the same bundle identifier.
	/// The dictionary is intentionally sparse so adding a repository never rewrites
	/// an existing user's choices.
	static func priority(for id: String) -> Int {
		(UserDefaults.standard.dictionary(forKey: priorityKey) as? [String: Int])?[id] ?? Int.max
	}

	static func orderedIDs(for ids: [String]) -> [String] {
		order(for: ids)
	}

	static func setOrder(_ ids: [String]) {
		var priorities: [String: Int] = [:]
		for (index, id) in ids.enumerated() { priorities[id] = index }
		UserDefaults.standard.set(priorities, forKey: priorityKey)
		// Keep the array as the human-readable, migration-friendly representation.
		UserDefaults.standard.set(ids, forKey: priorityKey + ".order")
	}

	/// Returns a stable source order while retaining the old dictionary format if
	/// an older build saved one. New builds use the explicit order array.
	static func order(for ids: [String]) -> [String] {
		let available = Set(ids)
		let stored = UserDefaults.standard.stringArray(forKey: priorityKey + ".order") ?? []
		if !stored.isEmpty {
			let known = stored.filter { available.contains($0) }
			let missing = ids.filter { !known.contains($0) }.sorted()
			return known + missing
		}
		// Migrate the first implementation, which stored only a priority map.
		if let legacy = UserDefaults.standard.dictionary(forKey: priorityKey) as? [String: Int], !legacy.isEmpty {
			return ids.sorted {
				let lhs = legacy[$0] ?? Int.max
				let rhs = legacy[$1] ?? Int.max
				if lhs != rhs { return lhs < rhs }
				return $0 < $1
			}
		}
		return ids.sorted()
	}

	// MARK: - User trust marker

	static func isTrusted(_ id: String) -> Bool {
		Set(UserDefaults.standard.stringArray(forKey: trustedKey) ?? []).contains(id)
	}

	static func setTrusted(_ id: String, trusted: Bool) {
		var values = Set(UserDefaults.standard.stringArray(forKey: trustedKey) ?? [])
		if trusted { values.insert(id) } else { values.remove(id) }
		UserDefaults.standard.set(Array(values).sorted(), forKey: trustedKey)
	}

	static func lastFetch(for id: String) -> Date? {
		guard let map = UserDefaults.standard.dictionary(forKey: lastFetchKey) as? [String: Double] else { return nil }
		guard let value = map[id] else { return nil }
		return Date(timeIntervalSince1970: value)
	}

	/// Date of the last *successful* refresh (distinct from `lastFetch`, which
	/// records every attempt and is used for the "Last Updated" sort).
	static func lastSuccess(for id: String) -> Date? {
		guard let map = UserDefaults.standard.dictionary(forKey: lastSuccessKey) as? [String: Double] else { return nil }
		guard let value = map[id] else { return nil }
		return Date(timeIntervalSince1970: value)
	}

	static func lastError(for id: String) -> String? {
		(UserDefaults.standard.dictionary(forKey: lastErrorKey) as? [String: String])?[id]
	}

	static func consecutiveFailures(for id: String) -> Int {
		(UserDefaults.standard.dictionary(forKey: failureCountKey) as? [String: Int])?[id] ?? 0
	}

	static func rateLimitedUntil(for id: String) -> Date? {
		guard let map = UserDefaults.standard.dictionary(forKey: rateLimitUntilKey) as? [String: Double] else { return nil }
		guard let value = map[id] else { return nil }
		return Date(timeIntervalSince1970: value)
	}

	/// Full health record for one repository.
	static func health(for id: String) -> Health {
		Health(
			id: id,
			lastAttempt: lastFetch(for: id),
			lastSuccess: lastSuccess(for: id),
			lastError: lastError(for: id),
			consecutiveFailures: consecutiveFailures(for: id),
			rateLimitedUntil: rateLimitedUntil(for: id)
		)
	}

	/// Health for every known repository id (union of all tracked keys).
	static func allHealth() -> [Health] {
		var ids = Set<String>()
		if let attempts = UserDefaults.standard.dictionary(forKey: lastFetchKey) as? [String: Double] {
			ids.formUnion(attempts.keys)
		}
		if let successes = UserDefaults.standard.dictionary(forKey: lastSuccessKey) as? [String: Double] {
			ids.formUnion(successes.keys)
		}
		if let errors = UserDefaults.standard.dictionary(forKey: lastErrorKey) as? [String: String] {
			ids.formUnion(errors.keys)
		}
		return ids.map { health(for: $0) }.sorted { ($0.lastSuccess ?? .distantPast) > ($1.lastSuccess ?? .distantPast) }
	}

	/// Removes every stored trace of a deleted repository.
	static func removeAllData(for id: String, automaticUpdateAlias: String? = nil) {
		for key in [lastFetchKey, lastSuccessKey, failureCountKey, rateLimitUntilKey] {
			var map = _dictionary(key) as [String: Double]
			map.removeValue(forKey: id)
			UserDefaults.standard.set(map, forKey: key)
		}
		var errors = _dictionary(lastErrorKey) as [String: String]
		errors.removeValue(forKey: id)
		UserDefaults.standard.set(errors, forKey: lastErrorKey)

		var autoUpdates: [String: Bool] = _dictionary(autoUpdatesKey)
		autoUpdates.removeValue(forKey: id)
		if let automaticUpdateAlias { autoUpdates.removeValue(forKey: automaticUpdateAlias) }
		UserDefaults.standard.set(autoUpdates, forKey: autoUpdatesKey)
	}

	static func recordFetch(id: String, error: String?) {
		recordFetch(id: id, error: error, rateLimited: false)
	}

	/// Records the outcome of one refresh attempt, maintaining the
	/// last-attempt/last-success distinction, consecutive failure counts and
	/// the rate-limit window.
	static func recordFetch(id: String, error: String?, rateLimited: Bool) {
		let now = Date().timeIntervalSince1970

		var fetches: [String: Double] = _dictionary(lastFetchKey)
		fetches[id] = now
		UserDefaults.standard.set(fetches, forKey: lastFetchKey)

		var errors: [String: String] = _dictionary(lastErrorKey)
		if let error, !error.isEmpty {
			errors[id] = error
		} else {
			errors.removeValue(forKey: id)
		}
		UserDefaults.standard.set(errors, forKey: lastErrorKey)

		var failures: [String: Int] = _dictionary(failureCountKey)
		if let error, !error.isEmpty {
			failures[id] = (failures[id] ?? 0) + 1
		} else {
			failures[id] = 0
			var successes: [String: Double] = _dictionary(lastSuccessKey)
			successes[id] = now
			UserDefaults.standard.set(successes, forKey: lastSuccessKey)
		}
		UserDefaults.standard.set(failures, forKey: failureCountKey)

		var limits: [String: Double] = _dictionary(rateLimitUntilKey)
		if rateLimited {
			// Honor a 429 Retry-After-ish window; a cap avoids absurd server values.
			limits[id] = now + 900
		} else {
			limits.removeValue(forKey: id)
		}
		UserDefaults.standard.set(limits, forKey: rateLimitUntilKey)
	}

	/// Typed UserDefaults dictionary read (nil-safe).
	private static func _dictionary<T>(_ key: String) -> [String: T] {
		guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: T] else { return [:] }
		return dict
	}

	private static var pinned: Set<String> {
		Set(UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [])
	}
}
