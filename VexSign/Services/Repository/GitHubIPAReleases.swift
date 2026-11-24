import Foundation
import NimbleExtensions

/// Public-release discovery only. Selected assets still go through VexSign's normal importer.
enum GitHubIPAReleases {
    enum Failure: LocalizedError, Equatable {
        case invalidRepository, invalidResponse, responseTooLarge, noAssets
        case requestFailed(Int)

        var errorDescription: String? {
            switch self {
            case .invalidRepository:
                return .localized("Enter owner/repository or an HTTPS GitHub repository URL.")
            case .invalidResponse:
                return .localized("GitHub returned an invalid release response.")
            case .responseTooLarge:
                return .localized("The GitHub release response exceeds the metadata size limit.")
            case .noAssets:
                return .localized("No IPA assets were found in this repository's recent releases. Prereleases are hidden unless enabled.")
            case .requestFailed(403), .requestFailed(429):
                return .localized("GitHub denied or rate-limited this request. Try again later.")
            case .requestFailed(404):
                return .localized("The public GitHub repository was not found.")
            case .requestFailed:
                return .localized("Could not retrieve GitHub releases. Try again later.")
            }
        }
    }

    struct Repository: Equatable, Sendable {
        let owner: String
        let name: String
        var slug: String { "\(owner)/\(name)" }

        init(_ input: String) throws {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = text.contains("://") ? text : "https://github.com/\(text)"
            guard let url = URLComponents(string: candidate),
                  url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil else { throw Failure.invalidRepository }
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
            // Only /owner/repository and an optional trailing slash are accepted.
            guard parts.first == "", parts.count == 3 || (parts.count == 4 && parts.last == "") else {
                throw Failure.invalidRepository
            }
            let owner = String(parts[1])
            let rawName = String(parts[2])
            let name = rawName.hasSuffix(".git") ? String(rawName.dropLast(4)) : rawName
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard [owner, name].allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
            }) else { throw Failure.invalidRepository }
            self.owner = owner
            self.name = name
        }

        /// Page size for the release listing. GitHub allows 100; asking for 20 was
        /// why an IPA published a few releases back could not be found at all.
        static let releasesPerPage = 100
        /// Manual paging is bounded: a miss must not turn one refresh into a crawl
        /// against the unauthenticated 60-requests-per-hour budget.
        static let maximumReleasePages = 3

        var request: URLRequest { request(page: 1) }

        func request(page: Int) -> URLRequest {
            // Components are restricted to ASCII path-safe characters in init.
            let url = URL(string: "https://api.github.com/repos/\(slug)/releases?per_page=\(Self.releasesPerPage)&page=\(page)")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            return request
        }
    }

    struct Asset: Decodable, Identifiable, Sendable {
        let id: Int64
        let name: String
        let browser_download_url: URL
        let size: Int64?
        let digest: String?

        var integrity: DownloadIntegrity.Expectation {
            DownloadIntegrity.Expectation(byteCount: size, sha256: digest)
        }

        private var hasValidIntegrityMetadata: Bool {
            if let size, size < 0 { return false }
            if let digest {
                guard digest.lowercased().hasPrefix("sha256:") else { return false }
                let hash = digest.dropFirst(7)
                let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
                guard hash.count == 64, hash.unicodeScalars.allSatisfy(hex.contains) else { return false }
            }
            return true
        }

        func isAllowed(for repository: Repository) -> Bool {
            guard hasValidIntegrityMetadata, name.lowercased().hasSuffix(".ipa"),
                  let components = URLComponents(url: browser_download_url, resolvingAgainstBaseURL: false),
                  components.scheme == "https", components.host?.lowercased() == "github.com",
                  components.user == nil, components.password == nil, components.port == nil,
                  components.query == nil, components.fragment == nil else { return false }
            let path = components.path.split(separator: "/").map(String.init)
            return path.count == 6 && path[0].lowercased() == repository.owner.lowercased()
                && path[1].lowercased() == repository.name.lowercased()
                && path[2] == "releases" && path[3] == "download"
                && !path.contains(".") && !path.contains("..")
                && path[5].lowercased().hasSuffix(".ipa")
        }
    }

    struct Release: Decodable, Identifiable, Sendable {
        let id: Int64
        let tag_name: String
        let name: String?
        let draft: Bool
        let prerelease: Bool
        var assets: [Asset]
    }

    static let metadataLimit = 2 * 1024 * 1024

    /// Every release in one response, without the review filters. Used to tell a
    /// full page from the last page while paging.
    static func decodeReleases(_ data: Data) throws -> [Release] {
        guard data.count <= metadataLimit else { throw Failure.responseTooLarge }
        do { return try JSONDecoder().decode([Release].self, from: data) }
        catch { throw Failure.invalidResponse }
    }

    static func decode(_ data: Data, repository: Repository, includePrereleases: Bool) throws -> [Release] {
        reviewable(try decodeReleases(data), repository: repository, includePrereleases: includePrereleases)
    }

    /// The releases a user may actually install from: not a draft, optionally not a
    /// prerelease, and carrying at least one asset that matches this repository.
    private static func reviewable(
        _ releases: [Release],
        repository: Repository,
        includePrereleases: Bool
    ) -> [Release] {
        releases.filter { !$0.draft && (includePrereleases || !$0.prerelease) }.compactMap { release in
            var result = release
            result.assets = release.assets.filter { $0.isAllowed(for: repository) }
            return result.assets.isEmpty ? nil : result
        }
    }

    struct MetadataResponse {
        let data: Data?
        let status: Int
        let etag: String?
        let retryAt: Date
    }

    /// Lists the installable releases, paging only when the first page has none.
    ///
    /// A release page is 100 entries now. The earlier single request asked for 20
    /// and reported "nothing found" for any IPA published before them, which looked
    /// like a repository problem rather than a listing limit. Extra pages are only
    /// fetched while nothing has matched, so the common case still costs one request.
    static func fetch(_ repository: Repository, includePrereleases: Bool) async throws -> [Release] {
        var matches: [Release] = []
        var seen = Set<Int64>()
        for page in 1...Repository.maximumReleasePages {
            let response = try await fetchMetadata(repository, page: page)
            guard response.status == 200, let data = response.data else {
                // A rejection on the first request is the caller's answer; a later
                // page failing after a successful one just ends the search.
                if page == 1 { throw Failure.requestFailed(response.status) }
                break
            }
            let decoded = try decodeReleases(data)
            for release in reviewable(decoded, repository: repository, includePrereleases: includePrereleases)
            where seen.insert(release.id).inserted {
                matches.append(release)
            }
            if !matches.isEmpty || decoded.count < Repository.releasesPerPage { break }
        }
        return matches
    }

    static func fetchMetadata(_ repository: Repository, etag: String? = nil, page: Int = 1) async throws -> MetadataResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = repository.request(page: page)
        if let etag, etag.count <= 512, !etag.contains("\r"), !etag.contains("\n") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme == "https", response.url?.host == "api.github.com" else {
            throw Failure.invalidResponse
        }
        let now = Date()
        let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
        let reset = Double(response.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "").map { $0 - now.timeIntervalSince1970 } ?? 0
        let denied = response.statusCode == 403 || response.statusCode == 429
        let delay = denied ? min(86400, max(60, max(seconds, reset))) : 60
        let retryAt = now.addingTimeInterval(delay)
        let tag = response.value(forHTTPHeaderField: "ETag").flatMap { $0.count <= 512 ? $0 : nil }
        if response.statusCode != 200 {
            return MetadataResponse(data: nil, status: response.statusCode, etag: tag, retryAt: retryAt)
        }
        guard response.expectedContentLength <= Int64(metadataLimit) else { throw Failure.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < metadataLimit else { throw Failure.responseTooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return MetadataResponse(data: data, status: response.statusCode, etag: tag, retryAt: retryAt)
    }
}
