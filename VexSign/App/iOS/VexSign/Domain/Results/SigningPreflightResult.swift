import Foundation

// MARK: - Issue
struct PreflightIssue: Identifiable, Equatable {
	enum Severity: Equatable {
		case warning
		case blocking
	}

	let id: String
	let title: String
	let detail: String
	let severity: Severity
	/// Stable classification, so the same finding can be logged, attributed and tested by code
	/// rather than by matching its English sentence.
	let code: SigningCapability.Issue.Code
	/// What the finding implies for the run. Defaults from `severity` and is overridden where
	/// the reason is more specific than "incompatible" — an expired profile is expired, not
	/// merely incompatible.
	let status: SigningCapabilityStatus
	/// The action that resolves the finding, when there is one the user can take.
	let remediation: String?

	init(
		_ title: String,
		_ detail: String,
		severity: Severity = .warning,
		code: SigningCapability.Issue.Code = .general,
		status: SigningCapabilityStatus? = nil,
		remediation: String? = nil
	) {
		self.id = "\(title)|\(detail)"
		self.title = title
		self.detail = detail
		self.severity = severity
		self.code = code
		self.status = status ?? (severity == .blocking ? .incompatible : .supported)
		self.remediation = remediation
	}

	/// A blocking finding iOS enforces at install. The sheet offers no way past it.
	var isMandatory: Bool { severity == .blocking && code.isMandatory }
}

// MARK: - Result
struct PreflightResult {
	let issues: [PreflightIssue]

	var hasBlocking: Bool { issues.contains { $0.severity == .blocking } }
	/// True when at least one finding cannot be signed through. "Sign Anyway" is offered
	/// only when every blocking finding is one the user may accept.
	var hasMandatoryFailure: Bool { issues.contains(where: \.isMandatory) }
	var canSignAnyway: Bool { hasBlocking && !hasMandatoryFailure }
	var isEmpty: Bool { issues.isEmpty }
}
