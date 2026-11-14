import Foundation
import NimbleExtensions

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
