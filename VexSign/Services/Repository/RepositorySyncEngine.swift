import Foundation
import CryptoKit

struct RepositorySnapshot: Codable, Sendable {
    let document: RepositoryDocument
    var checkedAt: Date
    let etag: String?
    let lastModified: String?
    let sha256: String
}

/// Conditional HTTP refresh, coalesced per URL, with a durable last-known-good snapshot.
/// HTTP validators avoid downloading/parsing unchanged feeds. This does not invent a
/// delta wire protocol for providers that only support full JSON responses.
actor RepositorySyncEngine {
    static let shared = RepositorySyncEngine()
    static let refreshInterval: TimeInterval = 6 * 60 * 60
    private var inFlight: [String: Task<RepositorySnapshot, Error>] = [:]

    func refresh(_ url: URL, format: RepositoryFormat = .altStore, force: Bool = false) async throws -> RepositorySnapshot {
        guard RepositoryValidator.webURL(url.absoluteString) != nil, url.scheme == "https" else {
            throw RepositoryError.invalid("Remote repositories require HTTPS.")
        }
        let key = "source:" + format.rawValue + ":" + url.absoluteString
        if let running = inFlight[key] { return try await running.value }
        let task = Task<RepositorySnapshot, Error> {
            let cached = try await EcosystemDatabase.shared.read(key, as: RepositorySnapshot.self)
            if let cached, !force, Date().timeIntervalSince(cached.checkedAt) < Self.refreshInterval { return cached }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue(cached?.etag, forHTTPHeaderField: "If-None-Match")
            request.setValue(cached?.lastModified, forHTTPHeaderField: "If-Modified-Since")
            let session = URLSession(configuration: .ephemeral, delegate: HTTPSRepositoryRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 304, var cached {
                cached.checkedAt = Date()
                try await EcosystemDatabase.shared.write(cached, key: key)
                return cached
            }
            guard http.statusCode == 200 else { throw RepositoryError.invalid("Repository returned HTTP \(http.statusCode).") }
            guard response.expectedContentLength <= RepositoryImporter.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            var data = Data()
            for try await byte in bytes {
                if data.count >= RepositoryImporter.maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
            try Task.checkCancellation()
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let document = try cached.flatMap { $0.sha256 == digest ? $0.document : nil } ?? RepositoryImporter.decode(data, format: format)
            let errors = RepositoryValidator.validate(document).filter { $0.severity == .error }
            guard errors.isEmpty else { throw RepositoryError.invalid(errors.map(\.message).joined(separator: "\n")) }
            let snapshot = RepositorySnapshot(document: document, checkedAt: Date(), etag: http.value(forHTTPHeaderField: "ETag"),
                                              lastModified: http.value(forHTTPHeaderField: "Last-Modified"), sha256: digest)
            try await EcosystemDatabase.shared.write(snapshot, key: key)
            return snapshot
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

private final class HTTPSRepositoryRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
