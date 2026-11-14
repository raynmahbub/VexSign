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

	public enum NBFetchServiceError: Error, LocalizedError {
		case invalidURL
		case networkError(Error)
		case noData
		case httpError(Int)
		case parsingError(Error)

		public var errorDescription: String? {
			switch self {
			case .invalidURL: "The URL is invalid."
			case .networkError(let error): "Network error: \(error.localizedDescription)"
			case .noData: "No data received."
			case .httpError(let code): "Server returned HTTP \(code)."
			case .parsingError(let error): "Failed to parse data: \(error.localizedDescription)"
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
	public func fetch<T: Decodable>(
		from urlString: String,
		headers: [String: String] = [:],
		completion: @escaping (Result<T, Error>) -> Void
	) {
		guard let url = URL(string: urlString) else {
			completion(.failure(NBFetchServiceError.invalidURL))
			return
		}

		fetch(from: url, headers: headers, completion: completion)
	}

	public func fetch<T: Decodable>(
		from url: URL,
		headers: [String: String] = [:],
		completion: @escaping (Result<T, Error>) -> Void
	) {
		fetchRaw(from: url, headers: headers) { result in
			switch result {
			case .success(let data):
				do {
					let decoder = JSONDecoder()
					let decodedData = try decoder.decode(T.self, from: data)
					completion(.success(decodedData))
				} catch {
					let snippet = String(data: data.prefix(512), encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
					Self.log.error("Request PARSE FAIL \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)\nBody: \(snippet, privacy: .public)")
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
	public func fetchRaw(
		from url: URL,
		headers: [String: String] = [:],
		completion: @escaping (Result<Data, Error>) -> Void
	) {
		// The completion runs on the URLSession callback queue; boxing it
		// keeps the @Sendable dispatch-queue closure Sendable-clean.
		final class CompletionBox: @unchecked Sendable {
			let handler: (Result<Data, Error>) -> Void
			init(_ handler: @escaping (Result<Data, Error>) -> Void) { self.handler = handler }
		}
		let box = CompletionBox(completion)

		DispatchQueue.global(qos: .userInitiated).async {
			// Create URLRequest with gzip support
			var request = URLRequest(url: url)
			request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
			request.cachePolicy = .reloadIgnoringLocalCacheData
			request.timeoutInterval = 30

			// Apply custom headers
			for (key, value) in headers {
				request.setValue(value, forHTTPHeaderField: key)
			}

			// Premium repository API key. Sourced from `apiKeyProvider` so the
			// NimbleJSON target never has to depend on AltSourceKit; the host app
			// registers a provider that returns `EsignSourceKey.customApiKey`.
			// Explicitly passed headers win over the ambient key.
			if
				request.value(forHTTPHeaderField: "X-API-Key") == nil,
				let key = Self.apiKeyProvider?(),
				!key.isEmpty {
				request.setValue(key, forHTTPHeaderField: "X-API-Key")
			}

			let task = Self.sharedSession.dataTask(with: request) { data, response, error in
				if let error = error {
					Self.log.error("Request FAILED \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
					box.handler(.failure(NBFetchServiceError.networkError(error)))
					return
				}

				let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

				guard let data = data else {
					Self.log.error("Request NO DATA \(url.absoluteString, privacy: .public) (HTTP \(statusCode, privacy: .public))")
					box.handler(.failure(NBFetchServiceError.noData))
					return
				}

				// Non-2xx responses are logged with a body snippet so auth/server
				// rejections (e.g. premium 401/403/422) are visible instead of
				// silently failing to decode and looking like an infinite load.
				if !(200..<300).contains(statusCode) {
					let snippet = String(data: data.prefix(512), encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
					Self.log.error("Request HTTP \(statusCode, privacy: .public) \(url.absoluteString, privacy: .public)\nBody: \(snippet, privacy: .public)")
					box.handler(.failure(NBFetchServiceError.httpError(statusCode)))
					return
				}

				Self.log.debug("Request OK (HTTP \(statusCode, privacy: .public)) \(url.absoluteString, privacy: .public)")
				box.handler(.success(data))
			}

			task.resume()
		}
	}
}
