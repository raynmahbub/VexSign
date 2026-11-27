// MARK: - Documented external hand-off
//
// A VexSign storage container is never itself launchable. This service builds
// the third-party LiveContainer URL shape with URLComponents and reports only
// what iOS actually accepted. `canOpenURL` is a query-scheme check, not proof
// that an app is installed, signed or able to launch a guest.

import Foundation
import UIKit
import NimbleExtensions

@MainActor
protocol ContainerURLOpening: AnyObject {
    func canOpenURL(_ url: URL) -> Bool
    func openURL(_ url: URL) async -> Bool
}

@MainActor
final class UIKitContainerURLOpener: ContainerURLOpening {
    func canOpenURL(_ url: URL) -> Bool { UIApplication.shared.canOpenURL(url) }

    func openURL(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }
}

@MainActor
final class ContainerURLHandoff {
    private let opener: any ContainerURLOpening

    init(opener: (any ContainerURLOpening)? = nil) {
        let resolved: any ContainerURLOpening = opener ?? UIKitContainerURLOpener()
        self.opener = resolved
    }

    /// LiveContainer reads `livecontainer://livecontainer-launch` with these
    /// exact query names. Unknown or malformed values are refused locally.
    static func makeLiveContainerURL(
        bundleIdentifier: String,
        openURL: URL? = nil,
        containerFolderName: String? = nil
    ) -> URL? {
        guard CatalogIdentity.isWellFormed(bundleIdentifier: bundleIdentifier) else { return nil }
        var components = URLComponents()
        components.scheme = "livecontainer"
        components.host = "livecontainer-launch"
        var items = [URLQueryItem(name: "bundle-name", value: bundleIdentifier)]
        if let openURL {
            guard let encoded = _encodedOpenURL(openURL) else { return nil }
            items.append(URLQueryItem(name: "open-url", value: encoded))
        }
        if let containerFolderName {
            guard let folder = try? ContainerPathPolicy.safeComponent(containerFolderName) else { return nil } // try? ok: an unsafe folder refuses the hand-off
            items.append(URLQueryItem(name: "container-folder-name", value: folder))
        }
        components.queryItems = items
        return components.url
    }

    func handoff(
        route: ContainerHandoffRoute,
        bundleIdentifier: String,
        openURL: URL? = nil
    ) async -> ContainerHandoffOutcome {
        switch route {
        case .embeddedHost:
            guard EmbeddedContainerRuntime.isAvailable else { return .rejected }
            // The host switch is a restart request, not evidence of a launch.
            return await MainActor.run { EmbeddedContainerRuntime.open(.container) }
                ? .embeddedHostRequested : .rejected
        case .liveContainerURLScheme:
            guard let url = Self.makeLiveContainerURL(bundleIdentifier: bundleIdentifier, openURL: openURL) else {
                return .invalidDestination
            }
            _ = opener.canOpenURL(url) // diagnostic only; never an installation claim
            return await opener.openURL(url) ? .openedUnverified : .rejected
        }
    }

    private static func _encodedOpenURL(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "livecontainer", "sidestore", "vexsign"].contains(scheme),
              url.user == nil, url.password == nil else { return nil }
        if ["http", "https"].contains(scheme), url.host == nil { return nil }
        return url.absoluteString.data(using: .utf8)?.base64EncodedString()
    }
}
