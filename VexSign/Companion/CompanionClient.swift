//
//  CompanionClient.swift
//  VexSign
//
//  Reads a companion snapshot from the iPhone's Web Manager. The three endpoints
//  already exist (`/api/status`, `/api/library`, `/api/updates`), so a companion
//  device needs nothing but the address — and the token, when the server requires
//  one. Foundation only, shared by the tvOS and visionOS apps.
//
//  Transport policy: HTTPS, with two explicit exceptions for a LAN.
//
//  The client sends a Web Manager password and API token. On a hostile network an
//  HTTP request hands both to whoever is listening, so HTTP is only used when the
//  user has turned on "Allow HTTP on this network" *and* the host really is a
//  local-network address. Neither the policy nor the request ever downgrades:
//  a typed `https://` address is never retried over HTTP, and a redirect to a
//  different scheme or host is refused rather than followed (which is also what
//  stops an `Authorization` header from being forwarded to a third party).
//

import Foundation

enum CompanionClientError: LocalizedError, Equatable {
	case missingAddress
	case invalidAddress
	case insecureTransport
	case unreachable(String)
	case unauthorized
	case decoding(String)

	var errorDescription: String? {
		switch self {
		case .missingAddress:
			return "No iPhone address is set. Enter the Web Manager URL shown in VexSign → Settings → Web Manager."
		case .invalidAddress:
			return "That address is not a valid https URL. Use the address the Web Manager "
				+ "prints, or turn on HTTP for a local network."
		case .insecureTransport:
			return "Plain HTTP is turned off. Use the https:// address the Web Manager "
				+ "prints, or turn on Allow HTTP on this network in the connect screen."
		case .unreachable(let detail):
			return "Could not reach the iPhone: \(detail)"
		case .unauthorized:
			return "The iPhone refused the connection. Check the Web Manager username, password and API token."
		case .decoding(let detail):
			return "The iPhone replied with something unexpected: \(detail)"
		}
	}
}

/// One-shot reader for the Web Manager API. No caching, no retries: companions
/// refresh on demand and on a timer, and show the last good snapshot meanwhile.
struct CompanionClient {
	var address: String
	var username: String?
	var password: String?
	var apiToken: String?
	/// Off by default. See the transport policy at the top of this file.
	var allowInsecureHTTP: Bool = false

	private static let _timeout: TimeInterval = 12

	func snapshot() async throws -> CompanionSnapshot {
		let status: CompanionStatus = try await _get("api/status")
		// A failed list is an empty list: /api/status already proved the session.
		let library: [CompanionLibraryEntry] = (try? await _get("api/library")) ?? [] // try? ok: optional list
		let updates: [CompanionUpdateEntry] = (try? await _get("api/updates")) ?? [] // try? ok: optional list

		return CompanionSnapshot(
			status: status,
			library: library,
			updates: updates,
			generatedAt: Date()
		)
	}

	// MARK: - Address policy

	/// The scheme `_get` will actually use, or the reason it will not.
	///
	/// Pure and separate from the request so the rules can be tested without a server.
	static func transport(for rawAddress: String, allowInsecureHTTP: Bool) throws -> URL {
		let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw CompanionClientError.missingAddress }

		// No scheme: prefer HTTPS when a host is typed. A bare `192.168.1.20:8080` gets
		// `https://`, not the `http://` this client used to add silently.
		let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
		guard let url = URL(string: normalized), let scheme = url.scheme?.lowercased() else {
			throw CompanionClientError.invalidAddress
		}
		guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
			throw CompanionClientError.invalidAddress
		}

		switch scheme {
		case "https":
			return url
		case "http":
			guard allowInsecureHTTP else { throw CompanionClientError.insecureTransport }
			// The opt-in covers a LAN, not the internet: a plaintext credential sent to a
			// public address is not made safer by the switch.
			guard isLocalNetworkHost(host) else { throw CompanionClientError.insecureTransport }
			return url
		default:
			throw CompanionClientError.invalidAddress
		}
	}

	/// Whether a host is one a local-network Web Manager can actually be reached on.
	///
	/// Covers the private IPv4 ranges, IPv6 link-local/unique-local, `.local` mDNS names
	/// and loopback. A public hostname or address is not "this network".
	static func isLocalNetworkHost(_ host: String) -> Bool {
		let lower = host.lowercased()

		if lower == "localhost" || lower == "::1" || lower.hasSuffix(".local") { return true }

		// IPv6 unique-local (fc00::/7) and link-local (fe80::/10), which are what an
		// iPhone on the same Wi-Fi reports.
		if lower.contains(":") {
			return lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("fe8")
				|| lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb")
		}

		let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]),
			  parts.allSatisfy({ Int($0).map { $0 >= 0 && $0 <= 255 } == true }) else {
			return false
		}

		switch (first, second) {
		case (127, _): return true            // loopback
		case (10, _): return true             // 10/8
		case (192, 168): return true          // 192.168/16
		case (172, 16...31): return true      // 172.16/12
		case (169, 254): return true          // link-local (self-assigned)
		default: return false
		}
	}

	// MARK: - Request

	private func _get<T: Decodable>(_ path: String) async throws -> T {
		let base = try Self.transport(for: address, allowInsecureHTTP: allowInsecureHTTP)
		let url = base.appendingPathComponent(path)

		var request = URLRequest(url: url)
		request.timeoutInterval = Self._timeout
		request.setValue("application/json", forHTTPHeaderField: "Accept")

		if let token = apiToken?.trimmingCharacters(in: .whitespaces), !token.isEmpty {
			request.setValue(token, forHTTPHeaderField: "X-VexSign-Token")
		}
		if let username, let password, !username.isEmpty {
			let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
			request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
		}

		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await URLSession.shared.data(for: request, delegate: SameOriginRedirects())
		} catch let error as CompanionClientError {
			throw error
		} catch {
			throw CompanionClientError.unreachable(error.localizedDescription)
		}

		guard let http = response as? HTTPURLResponse else {
			throw CompanionClientError.unreachable("no HTTP response")
		}
		if http.statusCode == 401 || http.statusCode == 403 {
			throw CompanionClientError.unauthorized
		}
		guard (200..<300).contains(http.statusCode) else {
			throw CompanionClientError.unreachable("HTTP \(http.statusCode)")
		}

		do {
			return try JSONDecoder().decode(T.self, from: data)
		} catch {
			throw CompanionClientError.decoding(error.localizedDescription)
		}
	}
}

/// Refuses every redirect.
///
/// `URLSession` keeps request headers — `Authorization` and `X-VexSign-Token`
/// included — when it follows a redirect, and a 30x to another host is exactly how
/// a malicious or compromised peer would collect them. The Web Manager answers the
/// three endpoints directly, so a redirect is never needed.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) {
		completionHandler(nil)
	}
}
