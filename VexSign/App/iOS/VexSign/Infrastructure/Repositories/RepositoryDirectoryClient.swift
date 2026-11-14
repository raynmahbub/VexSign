import Foundation
import AltSourceKit

/// The catalog-directory transport is not view code. Responses are bounded while
/// streaming, have a finite timeout, and cannot forward credentials to a new origin.
enum RepositoryDirectoryClient {
    static let maximumBytes = 2 * 1_024 * 1_024

    static func fetch() async throws -> [URL] {
        let url = VexSignAPI.reposListURL
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // The existing provider scopes repository credentials to their configured origin.
        for (name, value) in VexSignAPI.authHeaders(for: url) { request.setValue(value, forHTTPHeaderField: name) }
        if !EsignSourceKey.customApiKey.isEmpty {
            request.setValue(EsignSourceKey.customApiKey, forHTTPHeaderField: "X-API-Key")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let delegate = RepositoryDirectoryRedirectPolicy(origin: url)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url, Self.sameOrigin(finalURL, url),
              response.expectedContentLength <= Int64(maximumBytes) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        let entries = try JSONDecoder().decode([String].self, from: data)
        return try entries.map { entry in
            guard let url = URL(string: entry), url.host != nil,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil else { throw URLError(.unsupportedURL) }
            return url
        }
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
        lhs.host?.lowercased() == rhs.host?.lowercased() && (lhs.port ?? 443) == (rhs.port ?? 443) &&
        lhs.user == nil && lhs.password == nil
    }
}

private final class RepositoryDirectoryRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    private let lock = NSLock()
    private var redirects = 0
    init(origin: URL) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let permittedCount = redirects <= 5
        lock.unlock()
        guard permittedCount, let url = request.url, RepositoryDirectoryClient.sameOrigin(url, origin) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
