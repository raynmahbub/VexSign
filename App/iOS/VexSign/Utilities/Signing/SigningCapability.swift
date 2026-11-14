//
//  SigningCapability.swift
//  VexSign
//
//  What a signing run can actually do with the identity, profile and bundle it was
//  handed — as one answer instead of several.
//
//  Before this, the same question was answered in three places with three shapes:
//  `PreflightChecks` produced `PreflightIssue` values for one screen, `SigningIdentityPolicy`
//  produced a rejection for the pipeline, and `SigningMethodAvailability` produced a Bool for
//  the method picker. Batch, Update All, Shortcuts and self-update never rendered the preflight
//  list, so their only evidence was the identity rejection — a profile that did not cover an
//  extension, or a device that was not provisioned, reached the engine and failed an install
//  later with a message that named the signature.
//
//  This type does not add a fourth rule set. It gives the existing answers a common shape:
//  a stable code, a severity, the status that code implies, and — where one exists — the
//  action that resolves it. `SigningCapabilityResolver` collects them once, and every entry
//  point reads the same report.
//
//  Statuses are deliberately more than a Bool. "Expired" tells the user to renew, "unsupported"
//  tells them the bundle cannot work here at all, and "requires action" tells them the run is
//  possible once they do something. A Boolean cannot say which of those it is, and the screen
//  the user is looking at needs to.
//

import Foundation
import NimbleExtensions

// MARK: - Status

/// How far a run is from being able to start, from best to worst.
///
/// `Comparable` so a report can be reduced without a switch that has to be kept in step
/// with the cases: the worst issue wins.
enum SigningCapabilityStatus: String, Comparable, CaseIterable {
	/// Everything needed is present; advisories, if any, do not change what is possible.
	case supported
	/// The run can succeed once the user does something (import a profile, trust the device).
	case requiresAction
	/// The evidence contradicts itself or the intent is unclear (a different signer, a
	/// wildcard profile covering several bundles).
	case ambiguous
	/// The material is valid but does not fit this bundle, this team or this entitlement.
	case incompatible
	/// The material is structurally wrong and no user action can make it fit.
	case invalid
	/// The material was valid and is past its date.
	case expired
	/// The platform or the bundle shape is not supported by this app at all.
	case unsupported

	private var rank: Int {
		switch self {
		case .supported: 0
		case .requiresAction: 1
		case .ambiguous: 2
		case .incompatible: 3
		case .invalid: 4
		case .expired: 5
		case .unsupported: 6
		}
	}

	static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

	/// A sentence for a badge or a summary row.
	var title: String {
		switch self {
		case .supported: .localized("Ready")
		case .requiresAction: .localized("Needs your input")
		case .ambiguous: .localized("Check before signing")
		case .incompatible: .localized("Not compatible")
		case .invalid: .localized("Not usable")
		case .expired: .localized("Expired")
		case .unsupported: .localized("Not supported")
		}
	}
}

// MARK: - Capability

/// The verdict for one prospective run, with everything that led to it.
struct SigningCapability: Equatable {
	enum Severity: String, Equatable {
		/// The run must not start.
		case blocking
		/// The run may start; the user should know what it costs.
		case advisory
	}

	/// One reason, in a shape a screen, a log line and a test can all use.
	struct Issue: Identifiable, Equatable {
		/// Stable identifiers. These are asserted by tests and written to the signing log, so
		/// a case is renamed only when the reason itself changed.
		enum Code: String, CaseIterable {
			case certificateMissing
			case certificateExpired
			case certificateRevoked
			case certificatePasswordUnavailable
			case certificateNotInProfile
			case profileMissing
			case profileExpired
			case profileUnreadable
			case teamMismatch
			case appIdentifierMismatch
			case extensionNotCovered
			case entitlementNotGranted
			case deviceNotProvisioned
			case bundleIdentifierMissing
			case infoPlistUnreadable
			case executableUnavailable
			case executableUnsupportedPlatform
			case executableEncrypted
			case executablePlatformUnknown
			case minimumOSNewerThanDevice
			case deploymentTargetMismatch
			case storageInsufficient
			case injectionProblem
			case signerMismatch
			case nestedComponentInvalid
			/// A reason that predates the coded set. It is still reported; it is simply not
			/// classified yet, and treating it as generic is honest about that.
			case general

			/// Whether a blocking issue with this code is a requirement iOS enforces at
			/// install, so no confirmation can make the result installable.
			///
			/// These are refused before signing starts on every path, and the preflight
			/// sheet does not offer "Sign Anyway" for them. A blocking issue with any
			/// other code is a risk the user may accept.
			///
			/// `certificateNotInProfile` is deliberately not listed. It compares the first
			/// identity in the stored p12 with the profile, and a p12 that carries several
			/// identities can be reported when the engine would have used a matching one.
			/// It stays blocking and visible, and the post-sign check still judges the
			/// signer that was actually used.
			var isMandatory: Bool {
				switch self {
				case .certificateMissing, .certificateExpired, .certificateRevoked,
					 .profileExpired, .appIdentifierMismatch, .extensionNotCovered,
					 .entitlementNotGranted:
					true
				default:
					false
				}
			}
		}

		let code: Code
		let severity: Severity
		/// What this issue implies for the run, when it is the worst one present.
		let status: SigningCapabilityStatus
		let title: String
		let detail: String
		/// The action that resolves it, when one exists. Nil means "there is nothing the user
		/// can do from here", which is a different sentence from an empty one.
		let remediation: String?

		var id: String { "\(code.rawValue)|\(detail)" }

		init(
			code: Code,
			severity: Severity,
			status: SigningCapabilityStatus? = nil,
			title: String,
			detail: String,
			remediation: String? = nil
		) {
			self.code = code
			self.severity = severity
			// A blocking issue is incompatible by default; an advisory one does not change what
			// the run can do. Call sites override this when the reason is more specific.
			self.status = status ?? (severity == .blocking ? .incompatible : .supported)
			self.title = title
			self.detail = detail
			self.remediation = remediation
		}
	}

	let issues: [Issue]

	/// The worst status any single issue implies, or `.supported` when there are none.
	var status: SigningCapabilityStatus {
		issues.map(\.status).max() ?? .supported
	}

	var blocking: [Issue] { issues.filter { $0.severity == .blocking } }
	var advisories: [Issue] { issues.filter { $0.severity == .advisory } }

	/// Whether the run may start. This is the only thing a caller should branch on when it
	/// needs a Bool; everything else is for explaining the answer.
	var canProceed: Bool { blocking.isEmpty }

	/// Blocking issues that no confirmation can excuse. See `Issue.Code.isMandatory`.
	var mandatoryFailures: [Issue] { blocking.filter(\.code.isMandatory) }

	/// The refusal for a run that must not start, or nil when it may.
	var refusal: Refusal? {
		let failures = mandatoryFailures
		guard !failures.isEmpty else { return nil }
		return Refusal(issues: failures)
	}

	/// A run stopped before any file was copied, with the reasons that stopped it.
	struct Refusal: LocalizedError, Equatable {
		let issues: [Issue]

		var codes: [Issue.Code] { issues.map(\.code) }

		var errorDescription: String? {
			let reasons = issues.map { issue in
				issue.remediation.map { "\(issue.detail) \($0)" } ?? issue.detail
			}
			return .localized("Signing was not started. %@", arguments: reasons.joined(separator: " "))
		}
	}

	/// The sentence to put in front of the user when the run cannot start.
	var summary: String {
		guard let first = blocking.first else {
			return status.title
		}
		return first.remediation.map { "\(first.detail) \($0)" } ?? first.detail
	}

	init(issues: [Issue]) {
		self.issues = issues
	}

	/// Deterministic text for the signing log. One line per issue, worst status first,
	/// then ascending code, so two runs with the same inputs produce the same log.
	var logLines: [String] {
		issues
			.sorted {
				if $0.status != $1.status { return $0.status > $1.status }
				return $0.code.rawValue < $1.code.rawValue
			}
			.map { issue in
				let prefix = issue.severity == .blocking ? "Capability (\(issue.code.rawValue))" : "Capability note (\(issue.code.rawValue))"
				return "\(prefix): \(issue.detail)"
			}
	}
}

// MARK: - Resolver

/// Collects the existing checks into one report.
///
/// Deliberately not a new validator: the rules stay where they are (`PreflightChecks`,
/// `ProfileCompatibility`, `SigningIdentityPolicy`, `NestedBundleAudit`). This type only
/// runs them in one pass, in a fixed order, and translates the results into `SigningCapability`.
///
/// The certificate rule is not re-evaluated here. `PreflightChecks` now classifies a missing,
/// expired or revoked identity the same way `SigningIdentityPolicy` does, so running both would
/// report one problem twice; the pipeline keeps enforcing the policy itself, which is what makes
/// the refusal independent of whether a screen was shown.
@MainActor
enum SigningCapabilityResolver {
	/// Evaluates a prospective run without touching it.
	///
	/// - Parameters:
	///   - app: the library entry that would be signed.
	///   - options: the options the run would use.
	///   - certificate: the selected identity, if any.
	static func report(
		app: AppInfoPresentable,
		options: Options,
		certificate: CertificatePair?
	) -> SigningCapability {
		var issues: [SigningCapability.Issue] = []

		// Structural and compatibility checks. `PreflightChecks` owns these rules; this pass
		// only gives them codes and remediation.
		let preflight = PreflightChecks.run(app: app, options: options, certificate: certificate)
		issues.append(contentsOf: preflight.issues.map(issue(for:)))

		// What the bundle contains, and whether each nested component can be signed at all.
		// This is the same walk `NestedBundleAudit` and `SignatureVerifier` perform; doing it
		// once before the copy means a malformed extension is reported before two minutes of
		// work rather than after an install failure.
		if let bundle = Storage.shared.getAppDirectory(for: app) {
			let plan = SigningPlan.make(appBundle: bundle)
			issues.append(contentsOf: plan.validationIssues())
		}

		return SigningCapability(issues: issues)
	}

	// MARK: Translation

	/// Carries a preflight finding across, including the classification the check itself set.
	private static func issue(for preflight: PreflightIssue) -> SigningCapability.Issue {
		SigningCapability.Issue(
			code: preflight.code,
			severity: preflight.severity == .blocking ? .blocking : .advisory,
			status: preflight.status,
			title: preflight.title,
			detail: preflight.detail,
			remediation: preflight.remediation
		)
	}
}
