import Foundation
import XCTest
@testable import VexSign

final class GitHubIPAReleasesTests: XCTestCase {
    private func repository() throws -> GitHubIPAReleases.Repository {
        try GitHubIPAReleases.Repository("owner/project")
    }

    func testRepositoryAcceptsSlugAndHTTPSLink() throws {
        let expected = try repository()
        for input in ["owner/project", "  owner/project\n", "https://github.com/owner/project",
                      "https://github.com/owner/project/", "https://github.com/owner/project.git"] {
            XCTAssertEqual(try GitHubIPAReleases.Repository(input), expected)
        }
        XCTAssertEqual(expected.request.url?.absoluteString,
                       "https://api.github.com/repos/owner/project/releases?per_page=20")
        XCTAssertNil(expected.request.value(forHTTPHeaderField: "Authorization"))
    }

    func testRejectsNonRepositoryInputsAndCredentialURLs() {
        for input in ["", "owner", "owner/project/releases", "owner/project/extra",
                      "http://github.com/owner/project", "https://evil.test/owner/project",
                      "https://github.com.evil.test/owner/project", "https://user:secret@github.com/owner/project",
                      "https://github.com:443/owner/project", "https://github.com/owner/project?token=secret",
                      "https://github.com/owner/project#fragment", "owner/..", "owner/.git", "owner/pro%2Fject",
                      "owner//project", "owner/项目"] {
            XCTAssertThrowsError(try GitHubIPAReleases.Repository(input), input)
        }
    }

    private func asset(_ name: String = "App.ipa", url: String? = nil, id: Int = 1) -> [String: Any] {
        ["id": id, "name": name,
         "browser_download_url": url ?? "https://github.com/owner/project/releases/download/v1/\(name)"]
    }

    private func release(_ id: Int, prerelease: Bool = false, draft: Bool = false,
                         assets: [[String: Any]]) -> [String: Any] {
        ["id": id, "tag_name": "v\(id)", "name": NSNull(), "draft": draft,
         "prerelease": prerelease, "assets": assets]
    }

    private func decode(_ items: [[String: Any]], includePrereleases: Bool = false) throws -> [GitHubIPAReleases.Release] {
        try GitHubIPAReleases.decode(JSONSerialization.data(withJSONObject: items),
                                     repository: repository(), includePrereleases: includePrereleases)
    }

    func testStableDefaultAndExplicitPrereleasesNeverIncludeDrafts() throws {
        let payload = [release(1, assets: [asset()]),
                       release(2, prerelease: true, assets: [asset()]),
                       release(3, draft: true, assets: [asset()]),
                       release(4, assets: [asset("Notes.txt")])]
        XCTAssertEqual(try decode(payload).map(\.id), [1])
        XCTAssertEqual(try decode(payload, includePrereleases: true).map(\.id), [1, 2])
    }

    func testKeepsEveryValidIPAForExplicitUserChoice() throws {
        let result = try decode([release(1, assets: [asset("Phone.ipa"), asset("Tablet.IPA", id: 2)])])
        XCTAssertEqual(result.first?.assets.map(\.name), ["Phone.ipa", "Tablet.IPA"])
    }

    func testRejectsAssetsFromWrongHostRepositoryOrDownloadPath() throws {
        let urls = ["http://github.com/owner/project/releases/download/v1/App.ipa",
                    "https://evil.test/owner/project/releases/download/v1/App.ipa",
                    "https://github.com/other/project/releases/download/v1/App.ipa",
                    "https://github.com/owner/other/releases/download/v1/App.ipa",
                    "https://user:secret@github.com/owner/project/releases/download/v1/App.ipa",
                    "https://github.com:443/owner/project/releases/download/v1/App.ipa",
                    "https://github.com/owner/project/blob/main/App.ipa",
                    "https://github.com/owner/project/releases/download/v1/App.zip",
                    "https://github.com/owner/project/releases/download/v1/App.ipa?token=secret"]
        let invalid = urls.enumerated().map { asset(url: $0.element, id: $0.offset) }
        XCTAssertTrue(try decode([release(1, assets: invalid)]).isEmpty)
    }

    func testPreservesDeclaredIntegrityAndRejectsMalformedDeclarations() throws {
        var valid = asset()
        valid["size"] = 12345
        valid["digest"] = "sha256:" + String(repeating: "a", count: 64)
        let found = try XCTUnwrap(decode([release(1, assets: [valid])]).first?.assets.first)
        XCTAssertEqual(found.integrity.byteCount, 12345)
        XCTAssertEqual(found.integrity.sha256, String(repeating: "a", count: 64))
        for invalid in ["sha256:bad", "sha512:" + String(repeating: "a", count: 64)] {
            var item = valid
            item["digest"] = invalid
            XCTAssertTrue(try decode([release(1, assets: [item])]).isEmpty)
        }
        var negativeSize = valid
        negativeSize["size"] = -1
        XCTAssertTrue(try decode([release(1, assets: [negativeSize])]).isEmpty)
    }

    func testMetadataLimitAndMalformedResponsesFailClosed() throws {
        let repo = try repository()
        for data in [Data("not json".utf8), Data("{\"message\":\"Not Found\"}".utf8)] {
            XCTAssertThrowsError(try GitHubIPAReleases.decode(data, repository: repo, includePrereleases: false)) {
                XCTAssertEqual($0 as? GitHubIPAReleases.Failure, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try GitHubIPAReleases.decode(Data(repeating: 32, count: GitHubIPAReleases.metadataLimit + 1),
                                                         repository: repo, includePrereleases: false)) {
            XCTAssertEqual($0 as? GitHubIPAReleases.Failure, .responseTooLarge)
        }
        XCTAssertTrue(try decode([]).isEmpty)
    }
}
