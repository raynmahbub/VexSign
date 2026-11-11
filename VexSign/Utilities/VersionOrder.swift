//
//  VersionOrder.swift
//  VexSign
//
//  Version precedence, decided in one place.
//
//  Three comparators answered "is this newer?" before. `AppUpdateChecker` had a SemVer-aware one,
//  and `DownloadButtonView` had two copies of a dotted-integer one that dropped every component
//  that was not an `Int`:
//
//      let newComponents = new.split(separator: ".").compactMap { Int($0) }
//
//  So `"1.1-beta"` compared as `[1]` and lost to `"1.0"`'s `[1, 0]`: the App Store detail screen
//  said a beta of a newer version carried no update, while the Updates list (built on
//  `AppUpdateChecker`) offered that same version as one. Two screens, one install, opposite
//  answers.
//
//  Failing closed is deliberate and is the behaviour the update checker already documented: an
//  unparseable string is not a version, and guessing an order from it turns a metadata mistake
//  into an offered downgrade.
//

import Foundation

enum VersionOrder {
	/// Whether `candidate` is a later version than `reference`.
	///
	/// False when either side is not a version, in both directions — an unknown string can neither
	/// prove nor be proven newer.
	static func isNewer(_ candidate: String, than reference: String) -> Bool {
		precedence(candidate, reference) == .orderedDescending
	}

	/// How two versions compare, or nil when either is not a version this can order.
	static func precedence(_ lhs: String, _ rhs: String) -> ComparisonResult? {
		guard let left = Parsed(lhs), let right = Parsed(rhs) else { return nil }
		return left.precedence(to: right)
	}

	/// Ascending order for a list of optional versions, for `max(by:)`/`sorted(by:)`.
	///
	/// A version that can be parsed outranks a missing or unparseable one, so choosing "the newest
	/// installed copy" prefers the copy that actually reports a version. Two versions that cannot
	/// be ordered keep the caller's order, which keeps the selection stable.
	static func isOrderedBefore(_ lhs: String?, _ rhs: String?) -> Bool {
		let left = lhs.flatMap { Parsed($0) }
		let right = rhs.flatMap { Parsed($0) }
		switch (left, right) {
		case (nil, nil): return false
		case (nil, .some): return true
		case (.some, nil): return false
		case let (.some(lhs), .some(rhs)): return lhs.precedence(to: rhs) == .orderedAscending
		}
	}

	/// A version string split into the parts SemVer orders by.
	private struct Parsed {
		let core: [String]
		let prerelease: [String]?

		init?(_ rawValue: String) {
			var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
			if value.count > 1, let first = value.first, first == "v" || first == "V",
			   value.dropFirst().first?.isNumber == true {
				value.removeFirst()
			}

			// Build metadata does not affect SemVer precedence.
			value = String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])
			let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
			guard let coreText = pieces.first, !coreText.isEmpty else { return nil }
			let core = coreText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
			guard !core.isEmpty, core.allSatisfy({ Self.isASCIIDigits($0) }) else { return nil }

			if pieces.count == 2 {
				let identifiers = String(pieces[1])
					.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
				guard !identifiers.isEmpty, identifiers.allSatisfy({ identifier in
					!identifier.isEmpty && identifier.unicodeScalars.allSatisfy {
						(48...57).contains(Int($0.value)) || (65...90).contains(Int($0.value))
							|| (97...122).contains(Int($0.value)) || $0 == "-"
					}
				}) else { return nil }
				self.prerelease = identifiers
			} else {
				self.prerelease = nil
			}
			self.core = core
		}

		func precedence(to other: Parsed) -> ComparisonResult {
			for index in 0..<max(core.count, other.core.count) {
				let left = index < core.count ? core[index] : "0"
				let right = index < other.core.count ? other.core[index] : "0"
				let order = Self.compareNumeric(left, right)
				if order != .orderedSame { return order }
			}

			switch (prerelease, other.prerelease) {
			case (nil, nil):
				return .orderedSame
			case (nil, .some):
				return .orderedDescending // A release outranks its prereleases.
			case (.some, nil):
				return .orderedAscending
			case let (.some(left), .some(right)):
				for index in 0..<max(left.count, right.count) {
					if index >= left.count { return .orderedAscending }
					if index >= right.count { return .orderedDescending }
					// SemVer prerelease identifiers are case-sensitive ASCII.
					let lhs = left[index]
					let rhs = right[index]
					let lhsNumeric = Self.isASCIIDigits(lhs)
					let rhsNumeric = Self.isASCIIDigits(rhs)
					let order: ComparisonResult
					if lhsNumeric && rhsNumeric {
						order = Self.compareNumeric(lhs, rhs)
					} else if lhsNumeric != rhsNumeric {
						order = lhsNumeric ? .orderedAscending : .orderedDescending
					} else {
						order = lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
					}
					if order != .orderedSame { return order }
				}
				return .orderedSame
			}
		}

		private static func isASCIIDigits(_ value: String) -> Bool {
			!value.isEmpty && value.unicodeScalars.allSatisfy { (48...57).contains(Int($0.value)) }
		}

		/// Compared as numbers with leading zeros normalised, so `1.10` outranks `1.9` and `09`
		/// equals `9` — the comparison a dotted version needs and a string comparison cannot do.
		private static func compareNumeric(_ lhs: String, _ rhs: String) -> ComparisonResult {
			let left = String(lhs.drop(while: { $0 == "0" }))
			let right = String(rhs.drop(while: { $0 == "0" }))
			let normalizedLeft = left.isEmpty ? "0" : left
			let normalizedRight = right.isEmpty ? "0" : right
			if normalizedLeft.count != normalizedRight.count {
				return normalizedLeft.count < normalizedRight.count ? .orderedAscending : .orderedDescending
			}
			if normalizedLeft == normalizedRight { return .orderedSame }
			return normalizedLeft < normalizedRight ? .orderedAscending : .orderedDescending
		}
	}
}
