import Foundation
import UIKit
import NimbleExtensions

/// Launches an installed app and tells the user what happened.
///
/// `UIApplication.openApp(with:)` reaches LaunchServices private API. Apple can filter or remove
/// that API in any iOS release, and there is no public API that launches another app by bundle
/// identifier, so there is nothing to fall back to — the only honest answers are "dispatched" and
/// "this iOS version does not allow it". The primitive returns `Bool` for exactly that reason, but
/// a `false` that nobody reads leaves a dead Open button that is indistinguishable from a hung
/// one, so every user-facing launch goes through here instead of calling the primitive directly.
enum AppLauncher {
    /// Requests a launch of `identifier` and reports failure to the user.
    ///
    /// Success means the request reached the workspace, never that the target app is in the
    /// foreground: iOS gives no confirmation of the launch, and this does not invent one.
    static func open(_ identifier: String) {
        guard !identifier.isEmpty else {
            Toast.error(.localized("There is no bundle identifier to open."))
            return
        }
        guard UIApplication.openApp(with: identifier) else {
            Toast.error(.localized("This iOS version does not let VexSign open apps. Open it from the Home Screen."))
            return
        }
    }
}
