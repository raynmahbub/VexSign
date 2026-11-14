//
//  CatalogIdentity.swift
//  VexSign
//
//  What makes two catalog entries the same app, and two source addresses the same repository.
//
//  Neither question had an answer. Discovery grouped listings by the raw `CFBundleIdentifier`
//  string, so `com.Example.App` and `com.example.app` were two applications; the primary listing
//  for a bundle identifier was chosen with `max(by:)` over a dictionary's values, so two sources
//  publishing the same date picked whichever the hash order produced; and a listing's id was
//  `sourceURLString + "#" + bundleID`, which meant the same repository added with a trailing
//  slash produced a second, independent set of applications.
//
//  A random identifier is the opposite of identity: it changes on every parse, so nothing can be
//  grouped, deduplicated or compared across refreshes. Everything here is deterministic and
//  path-free, so the same catalog produces the same keys on any device.
//

import Foundation

enum CatalogIdentity {
    // MARK: Bundle identifiers

    /// The grouping key for a bundle identifier: trimmed and lowercased, or `nil` when there is
    /// nothing to group by.
    ///
    /// Case is not part of a bundle identifier's identity — it is a formatting choice — so
    /// `com.Example.App` and `com.example.app` must land in the same group. A listing with no
    /// identifier is not an application VexSign can match, install or update, so it returns
    /// `nil` rather than an empty key that would collect every broken listing under one id.
    static func bundleKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let key = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return key.isEmpty ? nil : key
    }

    /// Whether an identifier is *missing* or *malformed*.
    ///
    /// The two need different sentences: one listing never had an identifier, the other has a
    /// string that is present and cannot be installed. Grouping is deliberately lenient
    /// (`bundleKey` accepts anything non-empty); validation is where the difference is reported.
    static func isWellFormed(bundleIdentifier raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+$"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: Source addresses

    /// The comparison key for a repository address.
    ///
    /// Cases that are the same repository and used to produce different strings: upper-case
    /// scheme or host, an explicit default port, a trailing slash on the path, a fragment. The
    /// query is preserved — some catalogues are served as `?format=json` — and is not reordered,
    /// because reordering a query is not a normalization this app can justify for an address it
    /// does not own.
    ///
    /// Non-HTTP(S) addresses produce `nil`: a repository is fetched over the network, and
    /// `file://` or `data:` are not repositories.
    static func sourceKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return nil }

        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.query?.isEmpty == true {
            components.query = nil
        }

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path == "/" ? "" : path

        return components.url?.absoluteString
    }

    /// Whether two addresses name the same repository.
    static func isSameSource(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = sourceKey(lhs), let right = sourceKey(rhs) else { return false }
        return left == right
    }

    // MARK: Listings

    /// The stable id of one source's listing of one app.
    ///
    /// Scoped by source on purpose: two publishers can ship the same bundle identifier, and a
    /// listing is not the application. Grouping across publishers happens later, in
    /// `CanonicalAppGroup`, where every source option stays reachable.
    static func appID(source: String, bundleIdentifier: String?) -> String? {
        guard let bundle = bundleKey(bundleIdentifier) else { return nil }
        let sourceKey = self.sourceKey(source) ?? source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceKey.isEmpty else { return nil }
        return sourceKey + "#" + bundle
    }
}
