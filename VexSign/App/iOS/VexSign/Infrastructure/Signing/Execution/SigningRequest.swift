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
    /// Explicit consent to nonmandatory preflight risks only. Authentication,
    /// identifier/profile compatibility, required capabilities and final signature
    /// verification cannot be bypassed, regardless of this flag.
	let overridesBlockingPreflightIssues: Bool
	/// Lines the caller needs in this run's log, written as warnings once the run has started.
	///
	/// The pipeline clears the signing console when it begins, so anything a caller logs before
	/// starting is gone before the user can read it. A run that reuses saved settings uses this
	/// to say what it could not reuse.
	let notices: [String]
    var authorization: SigningResolutionAuthorization? = nil

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
