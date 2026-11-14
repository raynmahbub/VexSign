//
//  Haptics.swift
//  VexSign
//
//  Created by VexSign Team on 01.11.2026.
//

import UIKit

/// The app's only feedback entry point.
///
/// `UIImpactFeedbackGenerator` is a UIKit object and has to be created and
/// triggered on the main thread. The storage layer used to create one inline,
/// from whatever queue the caller happened to be on - the import and sign paths
/// run on a background queue, so the feedback either did nothing or touched
/// UIKit off-main. Haptics owns that hop, which also lets the storage
/// extensions drop their UIKit imports entirely.
enum Haptics {
	/// The light tap the library uses when a row is added or a repository is saved.
	@MainActor
	static func lightImpact() {
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
	}
}
