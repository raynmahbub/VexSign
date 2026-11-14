import Foundation
import UIKit
import NimbleExtensions

/// Bridge for existing library/presentation consumers; no UIKit or Core Data type
/// enters Domain. The work port is generic over the request and artifact types.
typealias SigningEvent = SigningWorkflowEvent<Signed>

/// What to sign, and how. A value, so it can cross into the work without dragging the caller's
/// state with it.
struct SigningRequest: Identifiable {
	let id: String
	let app: AppInfoPresentable
	let options: Options
	let icon: UIImage?
	let certificate: CertificatePair?
	/// True when the caller is the signing sheet after the user accepted blocking preflight
	/// issues ("Sign Anyway"). Post-sign profile/entitlement compatibility failures
    /// may be accepted, but structural failures and ignored options still reject output. Every path that never
	/// shows the preflight sheet — batch, Update All, automation, self-update — leaves this
	/// false and keeps the strict behaviour.
	let overridesBlockingPreflightIssues: Bool
	/// Lines the caller needs in this run's log, written as warnings once the run has started.
	///
	/// The pipeline clears the signing console when it begins, so anything a caller logs before
	/// starting is gone before the user can read it. A run that reuses saved settings uses this
	/// to say what it could not reuse.
	let notices: [String]

	init(
		id: String = UUID().uuidString,
		app: AppInfoPresentable,
		options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		overridesBlockingPreflightIssues: Bool = false,
		notices: [String] = []
	) {
		self.id = id
		self.app = app
		self.options = options
		self.icon = icon
		self.certificate = certificate
		self.overridesBlockingPreflightIssues = overridesBlockingPreflightIssues
		self.notices = notices
	}

	var name: String {
		app.name ?? .localized("app")
	}
}
