import Foundation
import XCTest
@testable import VexSign

final class GitHubReleaseSourceTests: XCTestCase {
    private let sourceURL = URL(string: "https://github.com/example/reader/releases")!

    func testRecognizesRepositoryAndReleasesURLs() throws {
        XCTAssertNotNil(GitHubReleaseSource.apiURL(for: URL(string: "https://github.com/owner/repo")!))
        XCTAssertNotNil(GitHubReleaseSource.apiURL(for: sourceURL))
        XCTAssertNotNil(GitHubReleaseSource.apiURL(for: URL(string: "https://github.com/owner/repo/releases/latest")!))
        XCTAssertNil(GitHubReleaseSource.apiURL(for: URL(string: "https://github.com/owner")!))
        XCTAssertNil(GitHubReleaseSource.apiURL(for: URL(string: "https://gitlab.com/owner/repo")!))
        XCTAssertNil(GitHubReleaseSource.apiURL(for: URL(string: "http://github.com/owner/repo")!))

        let apiURL = try XCTUnwrap(GitHubReleaseSource.apiURL(for: sourceURL))
        XCTAssertEqual(apiURL.absoluteString, "https://api.github.com/repos/example/reader/releases/latest")
    }

    func testAdaptsLatestIPAReleaseToAnAltStoreRepository() throws {
        let release = try releaseJSON(assets: [
            ["name": "Reader.ipa", "browser_download_url": "https://github.com/example/reader/releases/download/v2.4/Reader.ipa", "size": 1234]
        ])

        let repository = try GitHubReleaseSource.repository(from: release, sourceURL: sourceURL)
        XCTAssertEqual(repository.name, "example/reader")
        XCTAssertEqual(repository.id, "github.com/example/reader")
        XCTAssertEqual(repository.apps.count, 1)
        XCTAssertEqual(repository.apps[0].name, "Reader 2.4")
        XCTAssertEqual(repository.apps[0].developer, "example")
        XCTAssertEqual(repository.apps[0].currentVersion, "v2.4")
        XCTAssertEqual(repository.apps[0].currentDownloadUrl?.absoluteString,
                       "https://github.com/example/reader/releases/download/v2.4/Reader.ipa")
        XCTAssertEqual(repository.apps[0].currentAppVersion?.size, 1234)
        XCTAssertEqual(repository.apps[0].iconURL?.host, "github.com")
    }

    func testSourceLoaderUsesTheGitHubReleaseAdapter() async throws {
        let release = try releaseJSON(assets: [
            ["name": "Reader.ipa", "browser_download_url": "https://github.com/example/reader/releases/download/v2.4/Reader.ipa"]
        ])
        let loader = SourceFeedLoader(fetcher: { requestURL, headers in
            XCTAssertEqual(requestURL.absoluteString, "https://api.github.com/repos/example/reader/releases/latest")
            XCTAssertTrue(headers.isEmpty, "repository credentials must not be forwarded to GitHub's public API")
            return .success(release)
        })

        let result = await loader.load(url: sourceURL, headers: [:], identifier: "github-source")
        guard case let .decoded(repository, cachedPayload) = result.outcome else {
            return XCTFail("expected a decoded GitHub repository, got \(result.outcome)")
        }
        XCTAssertEqual(repository.name, "example/reader")
        XCTAssertEqual(repository.apps.first?.currentVersion, "v2.4")
        // What gets cached is the adapted AltStore feed, not GitHub's raw release response.
        // Assert on the decoded payload rather than on a substring of its bytes:
        // JSONSerialization escapes forward slashes by default, so the raw bytes read
        // "github.com\/example\/reader" and a plain substring check fails on a payload that is
        // in fact correct - which is exactly what this test did before.
        let cached = try JSONSerialization.jsonObject(with: cachedPayload) as? [String: Any]
        XCTAssertEqual(cached?["identifier"] as? String, "github.com/example/reader")
        XCTAssertEqual(cached?["website"] as? String, "https://github.com/example/reader")
        XCTAssertEqual((cached?["apps"] as? [[String: Any]])?.first?["downloadURL"] as? String,
                       "https://github.com/example/reader/releases/download/v2.4/Reader.ipa")
        XCTAssertNil(cached?["tag_name"],
                     "the cache must hold the adapted feed, not GitHub's raw release response")
    }

    func testRequiresAnIPAAsset() throws {
        let release = try releaseJSON(assets: [
            ["name": "Source.zip", "browser_download_url": "https://github.com/example/reader/archive/refs/tags/v2.4.zip"]
        ])

        XCTAssertThrowsError(try GitHubReleaseSource.feedPayload(from: release, sourceURL: sourceURL)) { error in
            XCTAssertEqual(error as? GitHubReleaseSource.Failure, .noIPA)
        }
    }

    func testRejectsAmbiguousMultipleIPAAssets() throws {
        let release = try releaseJSON(assets: [
            ["name": "Reader-arm64.ipa", "browser_download_url": "https://github.com/example/reader/releases/download/v2.4/arm64.ipa"],
            ["name": "Reader-universal.ipa", "browser_download_url": "https://github.com/example/reader/releases/download/v2.4/universal.ipa"]
        ])

        XCTAssertThrowsError(try GitHubReleaseSource.feedPayload(from: release, sourceURL: sourceURL)) { error in
            XCTAssertEqual(error as? GitHubReleaseSource.Failure, .multipleIPAs)
        }
    }

    func testRejectsNonHTTPSDownloadAssets() throws {
        let release = try releaseJSON(assets: [
            ["name": "Reader.ipa", "browser_download_url": "http://downloads.example/Reader.ipa"]
        ])

        XCTAssertThrowsError(try GitHubReleaseSource.feedPayload(from: release, sourceURL: sourceURL)) { error in
            XCTAssertEqual(error as? GitHubReleaseSource.Failure, .malformedRelease)
        }
    }

    private func releaseJSON(assets: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": "v2.4",
            "name": "Reader 2.4",
            "body": "Bug fixes and improvements",
            "published_at": "2026-10-30T12:00:00Z",
            "prerelease": false,
            "assets": assets
        ])
    }
}
