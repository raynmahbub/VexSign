import Foundation

// MARK: - Surface

/// What the installation sheet shows, as a pure function of the queue's published state.
///
/// This used to be an `if` chain inside the sheet's body, which is exactly why the presentation
/// races users reported could not be pinned down: a completion arriving just after Skip, a reset
/// landing under a scheduled dismissal, a sheet left spinning with nothing monitoring it. Same
/// chain, one place, assertable without a device:
///
///   * an installation genuinely in flight stays on screen;
///   * a terminal outcome always produces a surface the user can act on or leave;
///   * an idle queue presents nothing.
enum InstallQueueSurface: Equatable {
	/// Not presented: the queue is idle, or a terminal outcome dismissed the sheet.
	case hidden
	/// The run reached its end and is showing the summary.
	case finished(succeeded: Int, failed: Int)
	/// A failure — or an installation iOS never confirmed — with its recovery actions.
	case report(title: String, entryID: String?)
	/// A genuine installation in flight for this queue entry.
	case installing(entryID: String)
	/// Held between apps: the current install finished, the next is waiting for Resume.
	case paused(entryID: String)
	/// Presented and working, with no installer to draw a card for yet (packaging).
	case preparing

	static func resolve(
		isPresented: Bool,
		isFinished: Bool,
		failureTitle: String?,
		hasInstaller: Bool,
		isPaused: Bool,
		currentEntryID: String?,
		succeeded: Int = 0,
		failed: Int = 0
	) -> InstallQueueSurface {
		guard isPresented else { return .hidden }
		if isFinished { return .finished(succeeded: succeeded, failed: failed) }
		if let failureTitle { return .report(title: failureTitle, entryID: currentEntryID) }
		if hasInstaller, let currentEntryID { return .installing(entryID: currentEntryID) }
		if isPaused, let currentEntryID { return .paused(entryID: currentEntryID) }
		return .preparing
	}

	/// Whether an installation is still being monitored behind this surface.
	///
	/// The rule that was broken in both directions: the sheet must not vanish while iOS is
	/// genuinely installing, and must not spin on once monitoring has ended.
	var isMonitoring: Bool {
		switch self {
		case .installing, .paused, .preparing: return true
		case .hidden, .finished, .report: return false
		}
	}

	/// Whether the user is offered a way out. `.preparing` is the one surface that is not, and it
	/// is only ever transient: packaging ends in an installer or in a report.
	var isActionable: Bool { self != .preparing }
}
