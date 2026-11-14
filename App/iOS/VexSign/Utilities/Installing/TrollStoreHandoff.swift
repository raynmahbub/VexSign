//
//  TrollStoreHandoff.swift
//  VexSign
//
//  The one place VexSign talks to TrollStore.
//
//  TrollStore deliberately registers no URL scheme of its own: since 1.3 it
//  replaces Apple's `apple-magnifier` scheme so jailbreak detectors cannot spot
//  it. `TrollStore/TSSceneDelegate.m` only acts on two shapes —
//
//      apple-magnifier://install?url=<IPA URL>
//      apple-magnifier://enable-jit?bundle-id=<Bundle ID>
//
//  — and does nothing for any other host, including `trollstore://…`. On a
//  device without TrollStore (or with its "URL Scheme" setting off) the same
//  URL just opens Magnifier, so a hand-off must never be reported as success on
//  `open` alone. Detection has the mirror-image problem: every iOS device
//  answers `canOpenURL("apple-magnifier://")`, so that probe cannot be used to
//  claim TrollStore is installed.
//

import Foundation
import UIKit

enum TrollStoreHandoff {
    /// The only scheme TrollStore answers on. Not a detection signal on its own.
    static let scheme = "apple-magnifier"

    /// A handed-off install cannot be followed from here: TrollStore installs
    /// through its own helper and reports nothing back to the caller.
    enum Outcome: Equatable {
        /// iOS said it opened the URL. This is **not** proof of installation —
        /// it is equally the Magnifier app opening because TrollStore is absent.
        case openedUnverified
        /// iOS refused to open the URL.
        case openFailed
    }

    // MARK: - URLs

    /// `apple-magnifier://install?url=…`. The IPA URL's own query is preserved
    /// because it is carried as a single query value, not spliced into the URL.
    static func installURL(ipaURL: URL) -> URL? {
        componentURL(host: "install", item: URLQueryItem(name: "url", value: ipaURL.absoluteString))
    }

    /// `apple-magnifier://enable-jit?bundle-id=…` (TrollStore 2.0.12+).
    static func enableJITURL(bundleIdentifier: String) -> URL? {
        componentURL(host: "enable-jit", item: URLQueryItem(name: "bundle-id", value: bundleIdentifier))
    }

    /// Builds the URL with `URLComponents` so pre-existing percent-encoding in
    /// `ipaURL` is not double-encoded.
    private static func componentURL(host: String, item: URLQueryItem) -> URL? {
        guard var components = URLComponents(string: "\(scheme)://\(host)") else { return nil }
        components.queryItems = [item]
        return components.url
    }

    // MARK: - Detecting that TrollStore actually handled it

    /// Whether VexSign itself was installed by TrollStore.
    ///
    /// TrollStore copies `_TrollStore` / `_TrollStoreLite` next to the `.app` it
    /// installs and uses that marker to decide it may replace the app in place.
    /// The marker lives in the app's parent directory, which is outside the
    /// sandbox for a normal install, so this answers `false` there too — the
    /// check can only ever confirm, never prove absence.
    static func installedByTrollStore(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        let container = bundleURL.deletingLastPathComponent()
        return ["_TrollStore", "_TrollStoreLite"].contains {
            FileManager.default.fileExists(atPath: container.appendingPathComponent($0).path)
        }
    }

    // MARK: - Opening

    /// Opens a URL on TrollStore's documented scheme and reports what iOS
    /// actually did, without upgrading it to a success claim.
    @MainActor
    static func open(_ url: URL) async -> Outcome {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { accepted in
                continuation.resume(returning: accepted ? .openedUnverified : .openFailed)
            }
        }
    }

    /// Hands an IPA to TrollStore. Callers must describe the result as a
    /// hand-off, never as an installed app.
    @MainActor
    static func handOff(ipaURL: URL) async -> Outcome {
        guard let url = installURL(ipaURL: ipaURL) else { return .openFailed }
        return await open(url)
    }
}
