//
//  GitHubReleaseSource.swift
//  VexSign
//
//  Adapts a GitHub repository's latest release IPA asset to the AltStore feed
//  model used by Discover. The repository itself remains the saved source URL;
//  release metadata is fetched from GitHub's public API on each refresh.
//

import Foundation
import AltSourceKit
import NimbleExtensions

struct GitHubReleaseSource {
    enum Failure: LocalizedError, Equatable {
        case invalidRepositoryURL
        case httpStatus(Int)
        case malformedRelease
        case noIPA
        case multipleIPAs

        var errorDescription: String? {
            switch self {
            case .invalidRepositoryURL:
                return .localized("Enter a GitHub repository URL, such as github.com/owner/repository.")
            case .httpStatus(let status):
                return .localized("GitHub returned HTTP %lld while loading the latest release.", arguments: status)
            case .malformedRelease:
                return .localized("GitHub's latest release response could not be read.")
            case .noIPA:
                return .localized("The latest GitHub release has no .ipa asset.")
            case .multipleIPAs:
                return .localized("The latest release has multiple IPA assets. Use an AltStore source instead.")
            }
        }
    }

    private struct Coordinates {
        let owner: String
        let repository: String
    }

    /// Returns an API endpoint only for the github.com repository URL forms we support.
    /// Accepted forms: /owner/repo, /owner/repo/releases, /owner/repo/releases/latest.
    static func apiURL(for sourceURL: URL) -> URL? {
        guard let coordinates = coordinates(for: sourceURL) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(coordinates.owner)/\(coordinates.repository)/releases/latest"
        return components.url
    }

    static func isGitHubRepositoryURL(_ url: URL) -> Bool {
        coordinates(for: url) != nil
    }

    /// Converts one GitHub release API response into a small, ordinary AltStore feed.
    /// Release assets are untrusted; the adapter only accepts HTTPS browser-download URLs.
    static func feedPayload(from releaseData: Data, sourceURL: URL) throws -> Data {
        guard let coordinates = coordinates(for: sourceURL) else {
            throw Failure.invalidRepositoryURL
        }
        let releaseObject: Any
        do {
            releaseObject = try JSONSerialization.jsonObject(with: releaseData)
        } catch {
            throw Failure.malformedRelease
        }
        guard
            let release = releaseObject as? [String: Any],
            let tag = release["tag_name"] as? String,
            !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let assets = release["assets"] as? [[String: Any]]
        else {
            throw Failure.malformedRelease
        }

        let ipaAssets = assets.filter { asset in
            guard let name = asset["name"] as? String else { return false }
            return name.lowercased().hasSuffix(".ipa")
        }
        guard !ipaAssets.isEmpty else { throw Failure.noIPA }
        guard ipaAssets.count == 1, let asset = ipaAssets.first else { throw Failure.multipleIPAs }
        guard
            let rawURL = asset["browser_download_url"] as? String,
            let downloadURL = URL(string: rawURL),
            downloadURL.scheme?.lowercased() == "https",
            let assetName = asset["name"] as? String
        else {
            throw Failure.malformedRelease
        }

        guard let ownerIcon = URL(string: "https://github.com/\(coordinates.owner).png?size=256") else {
            throw Failure.malformedRelease
        }
        let appName = release["name"] as? String
        let displayName: String
        if let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayName = appName
        } else {
            displayName = coordinates.repository
        }
        let tagDescription = release["body"] as? String ?? ""
        let publishedAt = release["published_at"] as? String
        let size = asset["size"] as? Int
        let prerelease = release["prerelease"] as? Bool ?? false

        var version: [String: Any] = [
            "version": tag,
            "localizedDescription": tagDescription,
            "downloadURL": downloadURL.absoluteString
        ]
        if let publishedAt { version["date"] = publishedAt }
        if let size { version["size"] = size }
        var app: [String: Any] = [
            "name": displayName,
            "developerName": coordinates.owner,
            "iconURL": ownerIcon.absoluteString,
            "version": tag,
            "versionDescription": tagDescription,
            "downloadURL": downloadURL.absoluteString,
            "beta": prerelease,
            "versions": [version]
        ]
        if let size { app["size"] = size }
        let repository: [String: Any] = [
            "identifier": "github.com/\(coordinates.owner)/\(coordinates.repository)",
            "name": "\(coordinates.owner)/\(coordinates.repository)",
            "subtitle": "Latest GitHub release · \(assetName)",
            "website": "https://github.com/\(coordinates.owner)/\(coordinates.repository)",
            "iconURL": ownerIcon.absoluteString,
            "apps": [app]
        ]
        return try JSONSerialization.data(withJSONObject: repository, options: [.sortedKeys])
    }

    static func repository(from releaseData: Data, sourceURL: URL) throws -> ASRepository {
        let payload = try feedPayload(from: releaseData, sourceURL: sourceURL)
        return try JSONDecoder().decode(ASRepository.self, from: payload)
    }

    private static func coordinates(for url: URL) -> Coordinates? {
        guard
            url.scheme?.lowercased() == "https",
            url.host?.lowercased() == "github.com",
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else { return nil }

        var parts = url.path.split(separator: "/").map(String.init)
        if parts.last?.lowercased() == ".git" {
            parts.removeLast()
        }
        if parts.count == 4, parts[2].lowercased() == "releases", parts[3].lowercased() == "latest" {
            parts = Array(parts.prefix(2))
        } else if parts.count == 3, parts[2].lowercased() == "releases" {
            parts = Array(parts.prefix(2))
        }
        guard parts.count == 2 else { return nil }
        let owner = parts[0]
        var repository = parts[1]
        if repository.lowercased().hasSuffix(".git") {
            repository.removeLast(4)
        }
        guard !owner.isEmpty, !repository.isEmpty else { return nil }
        return Coordinates(owner: owner, repository: repository)
    }
}
