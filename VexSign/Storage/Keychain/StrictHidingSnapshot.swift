//
//  StrictHidingSnapshot.swift
//  VexSign
//
//  A thread-safe mirror of "this app must not appear outside its own screen".
//
//  Strict Hiding is documented to the user as: "completely excludes hidden apps
//  from search, widgets, and export suggestions until this vault is unlocked."
//  Search and the discovery surfaces live in views and can ask `AppLockManager`
//  directly, but two of those surfaces are not views at all:
//
//    * `WidgetStatusPublisher` writes the widget payload, and it is called from
//      storage mutations and from a background update pass;
//    * `BackupManager` enumerates the library while preparing a file copy.
//
//  Both are `@MainActor`-free by design, so reading the vault from there would
//  mean hopping to the main actor inside a file copy — or, worse, failing open
//  and silently including exactly the apps the user hid. Instead the vault
//  publishes a snapshot here whenever it changes, and those surfaces read it.
//
//  Two deliberate differences from `AppLockManager.isStrictlyHidden`:
//  strict-ness is captured at publish time (so a widget payload cannot become
//  stale mid-write), and an open vault session is *not* mirrored. Revealing the
//  vault shows rows on screen; it is not a reason for the widget tile or a backup
//  file to start naming hidden apps.
//

import Foundation
import os

/// Thread-safe read side of the Hidden Apps Vault, for code that is not a view.
///
/// The mutable state lives *inside* `OSAllocatedUnfairLock`, so the class holds one immutable
/// value of a `Sendable` type and is `Sendable` to the compiler. It used to be an `@unchecked`
/// escape around an `NSLock` and two stored properties, which asked a reader to verify by hand
/// that every access took the lock — and would have kept compiling if one stopped.
final class StrictHidingSnapshot: Sendable {
	static let shared = StrictHidingSnapshot()

	private struct State: Sendable {
		var isEnabled = false
		var hiddenAppUUIDs: Set<String> = []
	}

	private let state = OSAllocatedUnfairLock(initialState: State())

	/// Internal rather than private so a test can hold an isolated snapshot; the
	/// app reads `shared`, which `AppLockManager` keeps current.
	init() {}

	/// Replaces the snapshot. Called by `AppLockManager` after every vault change.
	func update(isEnabled: Bool, hiddenAppUUIDs: Set<String>) {
		state.withLock { current in
			current.isEnabled = isEnabled
			current.hiddenAppUUIDs = hiddenAppUUIDs
		}
	}

	/// Whether this app is strictly hidden right now.
	///
	/// A row without a UUID cannot be matched against the vault, so it stays
	/// visible: failing closed there would hide unrelated apps from their owner.
	func hides(_ uuid: String?) -> Bool {
		guard let uuid, !uuid.isEmpty else { return false }
		return state.withLock { $0.isEnabled && $0.hiddenAppUUIDs.contains(uuid) }
	}

	/// Current snapshot, for tests and diagnostics. Never used to gate a write.
	var snapshot: (isEnabled: Bool, hiddenAppUUIDs: Set<String>) {
		state.withLock { ($0.isEnabled, $0.hiddenAppUUIDs) }
	}
}
