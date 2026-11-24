import Foundation
import NimbleExtensions

extension InstallVerificationPolicy {
	// MARK: Wording

	/// The status line while the device is being asked.
	///
	/// The first check keeps the plain wording, because a count of one says nothing more. From
	/// the second on the count is shown, so a card that is still waiting visibly moves.
	static func statusLabel(attempt: Int) -> String {
		guard attempt > 1 else { return .localized("Verifying installation") }
		return .localized("Verifying installation (check %lld)", arguments: attempt)
	}
}
