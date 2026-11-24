//
//  PrivacySnapshotCover.swift
//  VexSign
//
//  The frame iOS keeps in the app switcher.
//
//  App Lock engages on `.background`, but iOS captures the switcher snapshot on
//  the way *there*: the app resigns active first, and nothing rendered in
//  `didEnterBackground` is guaranteed to reach the screen before the snapshot is
//  taken. So the last frame iOS could keep is an unlocked Library. This cover is
//  installed at `.inactive` instead — before the snapshot — and is deliberately
//  opaque and non-interactive.
//
//  It is not the lock. Locking at `.inactive` would re-prompt for every
//  permission sheet, share sheet and Control Centre visit; this cover only
//  obscures, and only for a user who opted into privacy by turning App Lock on.
//

import SwiftUI

struct PrivacySnapshotCover: View {
	var body: some View {
		ZStack {
			Theme.background
				.ignoresSafeArea()

			Image("LaunchLogo")
				.resizable()
				.scaledToFit()
				.frame(width: 96, height: 96)
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
		// No transition: it has to be on screen for the snapshot, not fade in
		// while the snapshot is taken.
		.transition(.identity)
	}
}
