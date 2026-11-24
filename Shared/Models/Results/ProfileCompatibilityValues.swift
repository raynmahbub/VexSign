import Foundation

enum ProfileCompatibility {
	// MARK: Target

	/// The app as it will be signed. Built by the caller because only it knows the options.
	struct Target {
		/// The identifier the app will carry after signing, or nil when it has none.
		let bundleIdentifier: String?
		/// Extensions and other nested bundles that must also be covered.
		let nestedBundleIdentifiers: [String]
		/// When enabled, known-uncovered nested bundles are removed before signing instead of
		/// blocking the main app. The main app's own coverage remains a hard requirement.
		let automaticallyRemoveUncoveredExtensions: Bool
		/// Identifiers known to be removable app extensions; watch apps must remain blocking.
		let removableExtensionIdentifiers: Set<String>
		/// Entitlements the user asked for (from a picked entitlements file), if any.
		let requestedEntitlements: [String: Any]
		/// The team the app is expected to belong to, when that is known independently of the
		/// profile — e.g. from an entitlements file written by another team's account.
		let teamIdentifier: String?
		/// The device this build is for, when it is known. A jailed app cannot read its own
		/// UDID, so this is nil unless a caller has one.
		let deviceUDID: String?
		/// App ID patterns of the certificate's additional (per-bundle) profiles. A nested
		/// bundle one of them covers is signed with that profile, so it is not "uncovered".
		var additionalProfilePatterns: [String] = []

		init(
			bundleIdentifier: String?,
			nestedBundleIdentifiers: [String] = [],
			automaticallyRemoveUncoveredExtensions: Bool = false,
			removableExtensionIdentifiers: Set<String>? = nil,
			requestedEntitlements: [String: Any] = [:],
			teamIdentifier: String? = nil,
			deviceUDID: String? = nil,
			additionalProfilePatterns: [String] = []
		) {
			self.bundleIdentifier = bundleIdentifier
			self.nestedBundleIdentifiers = nestedBundleIdentifiers
			self.automaticallyRemoveUncoveredExtensions = automaticallyRemoveUncoveredExtensions
			self.removableExtensionIdentifiers = removableExtensionIdentifiers
				?? (automaticallyRemoveUncoveredExtensions ? Set(nestedBundleIdentifiers) : [])
			self.requestedEntitlements = requestedEntitlements
			self.teamIdentifier = teamIdentifier
			self.deviceUDID = deviceUDID
			self.additionalProfilePatterns = additionalProfilePatterns
		}


	}

	// MARK: Verdict

	/// What a certificate's profile can do for a given app. Drives the badge in the picker.
	enum Verdict: Equatable {
		/// An explicit App ID that matches this app exactly.
		case covers
		/// A wildcard App ID that happens to cover this app.
		case wildcard
		/// The profile exists but cannot sign this app; `issues` says why.
		case unusable
		/// No profile on disk, or nothing to compare against.
		case unknown


	}

	// MARK: Issue

	struct Issue: Equatable {
		enum Severity: Equatable {
			case warning
			case blocking
		}

		enum Code: String, Equatable {
			case profileMissing
			case profileExpired
			case appIdentifierMismatch
			case extensionNotCovered
			case entitlementNotGranted
			case teamMismatch
			case certificateNotInProfile
			case deviceNotProvisioned
		}

		let code: Code
		let severity: Severity
		let detail: String

		var isBlocking: Bool { severity == .blocking }
	}

	// MARK: Evaluation

	struct Evaluation: Equatable {
		let verdict: Verdict
		let issues: [Issue]
		/// The identifier the profile would accept, when it names exactly one.
		let suggestedBundleIdentifier: String?

		var blockingIssues: [Issue] { issues.filter(\.isBlocking) }
		var hasBlocking: Bool { !blockingIssues.isEmpty }
	}

}
