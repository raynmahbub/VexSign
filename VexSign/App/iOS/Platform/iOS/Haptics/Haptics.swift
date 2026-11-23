//
//  Haptics.swift
//  VexSign
//
//  Created by VexSign Team on 01.11.2026.
//

import UIKit

/// The app's only feedback entry point.
///
/// `UIImpactFeedbackGenerator` and its siblings are UIKit objects: they have to be created and
/// triggered on the main thread. The storage and download layers used to build one inline, from
/// whatever queue the caller happened to be on — the import and sign paths run on a background
/// queue, so the feedback either did nothing or touched UIKit off-main. Haptics owns that hop,
/// which also lets callers drop their UIKit imports.
///
/// Every method is nonisolated so a caller does not have to wrap it in `Task { @MainActor in … }`
/// or reach for `DispatchQueue.main.async`; the hop is here, once.
///
/// `test_haptics_policy.py` fails when a feedback generator is constructed anywhere else, so a
/// new call site cannot quietly reintroduce the off-main shape or bypass the pacing below.
enum Haptics {
	/// The light tap the library uses when a row is added or a repository is saved.
	static func lightImpact() {
		onMain { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
	}

	/// A general control press, for surfaces that are not a list row edit.
	static func selection() {
		onMain { UISelectionFeedbackGenerator().selectionChanged() }
	}

	/// Something completed: a download, an import, a saved certificate.
	static func success() {
		onMain { UINotificationFeedbackGenerator().notificationOccurred(.success) }
	}

	/// Something completed, but the user should look: a check that only partly passed.
	static func warning() {
		onMain { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
	}

	/// Something failed.
	static func error() {
		onMain { UINotificationFeedbackGenerator().notificationOccurred(.error) }
	}

	/// Runs UIKit feedback on the main actor, immediately when the caller is already there.
	///
	/// Feedback that waits a runloop turn arrives after the scroll or the sheet animation it was
	/// meant to accompany, so the main-thread case is handled synchronously rather than through
	/// an unconditional `DispatchQueue.main.async`.
	private static func onMain(_ body: @escaping @MainActor () -> Void) {
		if Thread.isMainThread {
			MainActor.assumeIsolated { body() }
		} else {
			DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
		}
	}
}
