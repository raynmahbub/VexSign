//
//  ProfileApplicationIdentifierMatcher.swift
//  VexSign
//
//  The one place that decides whether a provisioning profile's `application-identifier`
//  authorizes a bundle identifier.
//
//  A profile names an App ID as `<prefix>.<pattern>`. The prefix is the App ID prefix: for
//  current accounts it equals the Team ID, for older App IDs it can be a different value, so
//  it is never compared with a Team ID here. The pattern is either an explicit bundle
//  identifier or a wildcard. A wildcard is a single `*` that is the whole pattern, or the
//  last component after a dot (`com.example.*`); it stands for one or more characters.
//  `com.example*` is not a wildcard App ID and is rejected as malformed rather than treated
//  as a string prefix.
//
//  Pure: no file access, no state.
//

import Foundation

enum ProfileApplicationIdentifierMatcher {
	// MARK: Parsed App ID

	/// A profile's authorized App ID, split into the parts that are compared separately.
	struct AuthorizedIdentifier: Equatable {
		/// The App ID prefix. Usually the Team ID, but not required to be.
		let prefix: String
		/// The bundle identifier pattern after the prefix: `com.example.app`, `com.example.*`
		/// or `*`.
		let pattern: String

		var isWildcard: Bool { pattern == "*" || pattern.hasSuffix(".*") }

		/// What an identifier must start with to match a wildcard. Empty for a bare `*`.
		var wildcardStem: String? {
			guard isWildcard else { return nil }
			return String(pattern.dropLast())
		}

		/// Apple issues ten-character prefixes. Other lengths are accepted, because the
		/// length is not what authorizes an app, but a caller may want to say so.
		var hasStandardPrefixLength: Bool { self.prefix.count == 10 }
	}

	// MARK: Diagnostics

	/// Why a profile's `application-identifier` could not be used at all.
	enum Malformation: String, Equatable, Error {
		case empty
		case missingPrefix
		case invalidPrefix
		case emptyPattern
		case misplacedWildcard
		case invalidCharacters
	}

	enum Outcome: Equatable {
		/// An explicit App ID that names this identifier.
		case exact
		/// A wildcard App ID that includes this identifier.
		case wildcard
		/// A well-formed App ID that does not include this identifier.
		case notAuthorized
		/// The entitlement value carries a different App ID prefix from the profile.
		case prefixMismatch
		/// The profile's own value cannot be parsed, so it authorizes nothing.
		case malformedProfile(Malformation)
		/// The identifier being checked is empty, has an empty component, or contains
		/// whitespace or an asterisk.
		case malformedIdentifier

		var isAuthorized: Bool { self == .exact || self == .wildcard }
	}

	/// The result of one comparison, with what was compared.
	struct Match: Equatable {
		let outcome: Outcome
		/// Nil when the profile value was malformed.
		let authorized: AuthorizedIdentifier?
		/// The bundle identifier that was compared, without any prefix.
		let bundleIdentifier: String

		var isAuthorized: Bool { outcome.isAuthorized }
	}

	// MARK: Parsing

	/// Splits `<prefix>.<pattern>` and validates both halves.
	static func parse(_ applicationIdentifier: String) -> Result<AuthorizedIdentifier, Malformation> {
		let value = applicationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !value.isEmpty else { return .failure(.empty) }
		guard let dot = value.firstIndex(of: ".") else { return .failure(.missingPrefix) }

		let prefix = String(value[..<dot])
		let pattern = String(value[value.index(after: dot)...])

		guard !prefix.isEmpty, prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
			return .failure(.invalidPrefix)
		}
		guard !pattern.isEmpty else { return .failure(.emptyPattern) }

		let stars = pattern.filter { $0 == "*" }.count
		if stars > 0 {
			// Exactly one, and it is the whole pattern or the whole last component.
			guard stars == 1, pattern == "*" || pattern.hasSuffix(".*") else {
				return .failure(.misplacedWildcard)
			}
		}

		let literal = stars == 0 ? pattern : String(pattern.dropLast())
		guard literal.isEmpty || _isIdentifierText(literal, allowsTrailingDot: stars > 0) else {
			return .failure(.invalidCharacters)
		}
		return .success(AuthorizedIdentifier(prefix: prefix, pattern: pattern))
	}

	// MARK: Matching

	/// Whether the profile authorizes a bundle identifier, which never carries a prefix.
	static func match(applicationIdentifier: String, bundleIdentifier: String) -> Match {
		let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
		switch parse(applicationIdentifier) {
		case .failure(let malformation):
			return Match(outcome: .malformedProfile(malformation), authorized: nil, bundleIdentifier: identifier)
		case .success(let authorized):
			guard _isIdentifierText(identifier, allowsTrailingDot: false) else {
				return Match(outcome: .malformedIdentifier, authorized: authorized, bundleIdentifier: identifier)
			}
			return Match(outcome: _compare(authorized, identifier), authorized: authorized, bundleIdentifier: identifier)
		}
	}

	/// Whether the profile authorizes a signed `application-identifier` entitlement value,
	/// which does carry a prefix. The prefixes must be equal.
	static func match(applicationIdentifier: String, entitlementValue: String) -> Match {
		let value = entitlementValue.trimmingCharacters(in: .whitespacesAndNewlines)
		switch parse(applicationIdentifier) {
		case .failure(let malformation):
			return Match(outcome: .malformedProfile(malformation), authorized: nil, bundleIdentifier: value)
		case .success(let authorized):
			guard let dot = value.firstIndex(of: ".") else {
				return Match(outcome: .malformedIdentifier, authorized: authorized, bundleIdentifier: value)
			}
			let prefix = String(value[..<dot])
			let identifier = String(value[value.index(after: dot)...])
			guard prefix == authorized.prefix else {
				return Match(outcome: .prefixMismatch, authorized: authorized, bundleIdentifier: identifier)
			}
			guard _isIdentifierText(identifier, allowsTrailingDot: false) else {
				return Match(outcome: .malformedIdentifier, authorized: authorized, bundleIdentifier: identifier)
			}
			return Match(outcome: _compare(authorized, identifier), authorized: authorized, bundleIdentifier: identifier)
		}
	}

	// MARK: Helpers

	private static func _compare(_ authorized: AuthorizedIdentifier, _ identifier: String) -> Outcome {
		guard let stem = authorized.wildcardStem else {
			return identifier == authorized.pattern ? .exact : .notAuthorized
		}
		// The asterisk stands for at least one character: `com.example.*` does not include
		// `com.example.` itself.
		return identifier.hasPrefix(stem) && identifier.count > stem.count ? .wildcard : .notAuthorized
	}

	/// Non-empty, no whitespace, no asterisk and no empty component.
	///
	/// Apple documents letters, digits, hyphen and period, but repackaged apps do ship
	/// identifiers with other characters and a wildcard App ID still covers them. Rejecting
	/// those here would refuse apps that sign and install, so only text that cannot be an
	/// identifier under any reading is refused.
	private static func _isIdentifierText(_ text: String, allowsTrailingDot: Bool) -> Bool {
		guard !text.isEmpty else { return false }
		guard !text.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "*" }) else {
			return false
		}
		var components = text.split(separator: ".", omittingEmptySubsequences: false)
		if allowsTrailingDot, components.last?.isEmpty == true { components.removeLast() }
		return !components.isEmpty && !components.contains(where: \.isEmpty)
	}
}
