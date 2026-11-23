//
//  AppMotion.swift
//  VexSign
//
//  Created by VexSign Team on 22.11.2026.
//

import SwiftUI
import UIKit

/// The app's motion vocabulary, and the one place that knows motion is optional.
///
/// Two idioms had grown side by side: `withAnimation(.spring(response: 0.35, dampingFraction:
/// 0.85))` repeated verbatim across the download headers, and a handful of views that each read
/// `@Environment(\.accessibilityReduceMotion)` and wrote `_reduceMotion ? nil : .smooth` by hand.
/// The first group ignored Reduce Motion entirely — the download header, the bubble, the store
/// and the signing sheet all animated for users who had asked the system to stop. The second
/// group got it right per-call-site, which means every new call site had to remember.
///
/// `withAppAnimation(_:_:)` and `.appAnimation(_:value:)` answer the question once. The value is
/// read at fire time rather than snapshotted, so turning the setting off in Control Centre takes
/// effect on the next interaction instead of needing a relaunch.
///
/// `test_motion_policy.py` fails on a bare `withAnimation(` or on `.animation(_:value:)` with a
/// non-nil curve outside this folder, so a new surface cannot reintroduce either idiom.
enum AppMotion {
	/// A press, a toggle, a row arriving: fast enough not to feel like a transition.
	static let quick = Animation.spring(response: 0.28, dampingFraction: 0.82)

	/// A header or a sheet section changing size.
	static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)

	/// A card or the download bubble arriving.
	static let emphasized = Animation.spring(response: 0.5, dampingFraction: 0.7)

	/// A selection moving between segments or tabs.
	static let selection = Animation.snappy

	/// A colour or opacity crossfade.
	static let fade = Animation.easeInOut(duration: 0.25)

	/// Whether the user asked the system for less motion. Read per call, not cached.
	@MainActor
	static var isReduceMotionEnabled: Bool {
		UIAccessibility.isReduceMotionEnabled
	}

	/// The animation to use, or `nil` — which SwiftUI reads as "no animation" — when the user
	/// asked for less motion.
	@MainActor
	static func resolved(_ animation: Animation) -> Animation? {
		isReduceMotionEnabled ? nil : animation
	}
}

/// `withAnimation`, except it does nothing when the user asked for less motion.
///
/// The body still runs; only the animation is dropped, so state changes keep their ordering and
/// their `onChange`/`task` side effects.
@MainActor
func withAppAnimation(_ animation: Animation = AppMotion.standard, _ body: () -> Void) {
	withAnimation(AppMotion.resolved(animation), body)
}

extension View {
	/// `.animation(_:value:)`, except it does nothing when the user asked for less motion.
	func appAnimation<V: Equatable>(_ animation: Animation = AppMotion.standard, value: V) -> some View {
		modifier(AppAnimationModifier(animation: animation, value: value))
	}
}

private struct AppAnimationModifier<V: Equatable>: ViewModifier {
	let animation: Animation
	let value: V

	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func body(content: Content) -> some View {
		content.animation(reduceMotion ? nil : animation, value: value)
	}
}
