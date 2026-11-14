//
//  NBHaptic.swift
//  NimbleKit
//
//  Tiny wrapper around UIFeedbackGenerator so tactile feedback is one call site.
//

#if canImport(UIKit)
import UIKit

/// Tactile feedback, fire-and-forget.
///
/// `UIFeedbackGenerator` is main-actor isolated, and the callers are a mix of
/// button actions and `Binding` setters — the latter are `@Sendable` closures,
/// so `@MainActor` here would push an isolation error onto every call site.
/// The hop to the main actor is therefore done once, in this file: a haptic is
/// a nudge felt a few milliseconds later, never a result anything waits on.
public enum NBHaptic {
	/// A light tap — for primary button presses (install, get, update, sign).
	public static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
		Task { @MainActor in
			let generator = UIImpactFeedbackGenerator(style: style)
			generator.prepare()
			generator.impactOccurred()
		}
	}

	/// A semantic notification — for success/warning/error outcomes.
	public static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
		Task { @MainActor in
			let generator = UINotificationFeedbackGenerator()
			generator.prepare()
			generator.notificationOccurred(type)
		}
	}

	/// A selection change — for toggles / pickers.
	public static func selection() {
		Task { @MainActor in
			let generator = UISelectionFeedbackGenerator()
			generator.prepare()
			generator.selectionChanged()
		}
	}
}
#endif
