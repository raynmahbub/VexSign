//
//  FetchService.swift
//  Loader
//
//  Created by VexSign Contributors on 14.03.2025.
//

import Foundation
import OSLog

// MARK: - Class
public class NBFetchService {

	private static let log = Logger(subsystem: "com.vexsign.network", category: "NBFetchService")
	private static let sharedSession = URLSession(
		configuration: .default,
		delegate: NBFetchRedirectDelegate(),
		delegateQueue: nil
	)

	/// Dependency-free hook the host app registers once at startup to supply the
	/// premium repository API key (e.g. `{ EsignSourceKey.customApiKey }`).
	/// When it returns a non-empty string, every request receives it as `X-API-Key`.
	///
	/// `nonisolated(unsafe)` keeps this building in Swift 6 language mode (this
	/// package declares swift-tools-version 6.0, which rejects unsynchronized
	/// shared mutable state outright). It is safe here because the property is
	/// assigned exactly once — on the main thread at launch, via
	/// `RepositoryCatalogService.registerRepositoryKeyProvider()` — before any fetch runs; afterwards
	/// the background queues in `fetch(from:headers:completion:)` only read it.
	nonisolated(unsafe) public static var apiKeyProvider: (() -> String)?
	/// Host-scoped variant preferred when the caller distinguishes premium feeds from
	/// arbitrary third-party repositories so `X-API-Key` is not sent to untrusted hosts.
	nonisolated(unsafe) public static var scopedApiKeyProvider: ((URL) -> String?)?

	public enum NBFetchServiceError: Error, LocalizedError {
		case invalidURL
		case networkError(Error)
		case noData
		case httpError(Int)
		case parsingError(Error)
		case responseTooLarge(Int)

		public var errorDescription: String? {
			switch self {
			case .invalidURL: "The URL is invalid."
			case .networkError(let error): "Network error: \(error.localizedDescription)"
			case .noData: "No data received."
			case .httpError(let code): "Server returned HTTP \(code)."
			case .parsingError(let error): "Failed to parse data: \(error.localizedDescription)"
			case .responseTooLarge(let limit): "The response is larger than the \(limit)-byte limit for a repository feed."
			}
		}
	}

	public init() {}

	/// Reject insecure scheme downgrades on URLSession redirects and prevent
	/// credentials from following a request to a different origin. The original
	/// request is still governed by its caller's explicit URL policy (some users
	/// opt into HTTP for a trusted local repository).
	public static func safeRedirectRequest(from source: URL?, to request: URLRequest) -> URLRequest? {
		guard let source,
		      let destination = request.url,
		      isHTTPURL(source), isHTTPURL(destination),
		      destination.user == nil, destination.password == nil else { return nil }
		let sourceScheme = source.scheme!.lowercased()
		let destinationScheme = destination.scheme!.lowercased()
		guard destinationScheme != "http" || sourceScheme == "http" else { return nil }

		var safeRequest = request
		if origin(source) != origin(destination) {
			for header in ["Authorization", "Proxy-Authorization", "Cookie", "Cookie2", "X-API-Key", "vexSignUUID"] {
				safeRequest.setValue(nil, forHTTPHeaderField: header)
			}
		}
		return safeRequest
	}

	private static func isHTTPURL(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
		      let host = url.host, !host.isEmpty,
		      url.user == nil, url.password == nil else { return false }
		return true
	}

	private static func origin(_ url: URL) -> String {
		let scheme = url.scheme!.lowercased()
		let host = url.host!.lowercased()
		let port = url.port ?? (scheme == "https" ? 443 : 80)
		return "\(scheme)://\(host):\(port)"
	}
}

private final class NBFetchRedirectDelegate: NSObject, URLSessionTaskDelegate {
	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) {
		completionHandler(NBFetchService.safeRedirectRequest(from: response.url, to: request))
	}
}

// MARK: - Class extension: fetch
extension NBFetchService {
	/// Ceiling for one response body. A repository feed is metadata: the catalog
	/// and sync paths already refuse anything above 20 MB, and a directory
	/// listing above 2 MB is not a feed. The limit exists so a hostile or broken
	/// host cannot make the app allocate an unbounded buffer before anyone
	/// inspects the payload.
	public static let defaultMaxBytes = 20 * 1024 * 1024

	/// Host-only description used in logs. The full URL can carry credentials,
	/// premium tokens or signed download parameters, and the log stream is
	/// readable by the system and included in diagnostics.
	static func logTarget(_ url: URL) -> String {
		guard let host = url.host, !host.isEmpty else { return "<no host>" }
		return url.port.map { "\(host):\($0)" } ?? host
	}

	public func fetch<T: Decodable>(
		from urlString: String,
		headers: [String: String] = [:],
		maxBytes: Int = NBFetchService.defaultMaxBytes,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		guard let url = URL(string: urlString) else {
			completion(.failure(NBFetchServiceError.invalidURL))
			return
		}

		fetch(from: url, headers: headers, maxBytes: maxBytes, completion: completion)
	}

	public func fetch<T: Decodable>(
		from url: URL,
		headers: [String: String] = [:],
		maxBytes: Int = NBFetchService.defaultMaxBytes,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		fetchRaw(from: url, headers: headers, maxBytes: maxBytes) { result in
			switch result {
			case .success(let data):
				do {
					let decoder = JSONDecoder()
					let decodedData = try decoder.decode(T.self, from: data)
					completion(.success(decodedData))
				} catch {
					// The body is not logged: feeds can be private, and a snippet is
					// enough to identify an account or a signed download URL.
					Self.log.error("Request PARSE FAIL \(Self.logTarget(url), privacy: .public): \(error.localizedDescription, privacy: .public) (\(data.count, privacy: .public) bytes)")
					completion(.failure(NBFetchServiceError.parsingError(error)))
				}
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	/// Fetches the raw response body. Host apps use this when they need the
	/// undecoded payload — e.g. to keep an offline snapshot of a repository
	/// that can be re-decoded later without another request.
	///
	/// The transfer goes to disk (`downloadTask`) rather than into a growing
	/// `Data`, so `maxBytes` is a real ceiling: the decoded size is checked before
	/// the body is read, and a response that exceeds it fails with
	/// `responseTooLarge` instead of being buffered into memory.
	public func fetchRaw(
		from url: URL,
		headers: [String: String] = [:],
		maxBytes: Int = NBFetchService.defaultMaxBytes,
		completion: @escaping (Result<Data, Error>) -> Void
	) {
		// The completion runs on the URLSession callback queue; boxing it
		// keeps the @Sendable dispatch-queue closure Sendable-clean.
		final class CompletionBox: @unchecked Sendable {
			let handler: (Result<Data, Error>) -> Void
			init(_ handler: @escaping (Result<Data, Error>) -> Void) { self.handler = handler }
		}
		let box = CompletionBox(completion)
		let limit = max(1, maxBytes)

		DispatchQueue.global(qos: .userInitiated).async {
			var request = URLRequest(url: url)
			request.cachePolicy = .reloadIgnoringLocalCacheData
			request.timeoutInterval = 30
			// `Accept-Encoding` is deliberately not set. URLSession negotiates it
			// and decodes the body itself; setting the header manually hands this
			// code compressed bytes that nothing here inflates.

			// Apply custom headers
			for (key, value) in headers {
				request.setValue(value, forHTTPHeaderField: key)
			}

			// Premium repository API key. Sourced from `apiKeyProvider` so the
			// NimbleJSON target never has to depend on AltSourceKit; the host app
			// registers a provider that returns `EsignSourceKey.customApiKey`.
			// Explicitly passed headers win over the ambient key.
			if request.value(forHTTPHeaderField: "X-API-Key") == nil {
				let resolvedKey: String?
				if let scoped = Self.scopedApiKeyProvider {
					resolvedKey = scoped(url)
				} else {
					resolvedKey = Self.apiKeyProvider?()
				}
				if let key = resolvedKey, !key.isEmpty {
					request.setValue(key, forHTTPHeaderField: "X-API-Key")
				}
			}

			let task = Self.sharedSession.downloadTask(with: request) { location, response, error in
				if let error = error {
					Self.log.error("Request FAILED \(Self.logTarget(url), privacy: .public): \(error.localizedDescription, privacy: .public)")
					box.handler(.failure(NBFetchServiceError.networkError(error)))
					return
				}

				let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

				guard let location else {
					Self.log.error("Request NO DATA \(Self.logTarget(url), privacy: .public) (HTTP \(statusCode, privacy: .public))")
					box.handler(.failure(NBFetchServiceError.noData))
					return
				}

				// The downloaded file holds the decoded body, so this is the size the
				// caller would actually have to hold. It is checked before any read.
				let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
				let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
				guard byteCount <= limit else {
					Self.log.error("Request TOO LARGE \(Self.logTarget(url), privacy: .public) (HTTP \(statusCode, privacy: .public)): \(byteCount, privacy: .public) bytes, limit \(limit, privacy: .public)")
					box.handler(.failure(NBFetchServiceError.responseTooLarge(limit)))
					return
				}

				// Non-2xx responses are reported with the status and host only, so
				// auth/server rejections stay diagnosable without copying a body
				// snippet into the system log.
				guard (200..<300).contains(statusCode) else {
					Self.log.error("Request HTTP \(statusCode, privacy: .public) \(Self.logTarget(url), privacy: .public) (\(byteCount, privacy: .public) bytes)")
					box.handler(.failure(NBFetchServiceError.httpError(statusCode)))
					return
				}

				guard let data = try? Data(contentsOf: location) else {
					Self.log.error("Request UNREADABLE \(Self.logTarget(url), privacy: .public) (HTTP \(statusCode, privacy: .public))")
					box.handler(.failure(NBFetchServiceError.noData))
					return
				}

				Self.log.debug("Request OK (HTTP \(statusCode, privacy: .public)) \(Self.logTarget(url), privacy: .public) (\(data.count, privacy: .public) bytes)")
				box.handler(.success(data))
			}

			task.resume()
		}
	}
}
