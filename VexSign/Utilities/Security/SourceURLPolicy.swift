//
//  SourceURLPolicy.swift
//  VexSign
//
//  Central URL policy for repositories (sources).
//
//  Repositories deliver app catalogs and download links that VexSign fetches
//  and signs on device. They are treated as untrusted input, so the transport
//  must be HTTPS by default: a plaintext HTTP catalog can be tampered with on
//  the network, silently swapping the IPA a user later installs.
//
//  HTTP stays available as an explicit, clearly-labeled opt-in for users on
//  local networks (e.g. a self-hosted repository on a LAN) — it is off by
//  default and the setting states the risk.
//

import Foundation
import NimbleExtensions

enum SourceURLPolicy {
	enum Failure: LocalizedError {
		case notHTTPS
		case invalidAuthority
		case unsupportedScheme(String)

		var errorDescription: String? {
			switch self {
			case .notHTTPS:
				String.localized("Repositories must use HTTPS. Enable 'Allow Insecure HTTP Sources' in Settings → Security if you really need a local HTTP repository.")
			case .invalidAuthority:
				String.localized("Repository URLs must have a host and must not embed a username or password.")
			case .unsupportedScheme(let scheme):
				String.localized("Unsupported URL scheme '%@'. Repositories must use https.", arguments: scheme)
			}
		}
	}

	static let allowInsecureHTTPKey = "VexSign.sources.allowInsecureHTTP"

	/// Off by default: HTTP repositories are only allowed after an explicit opt-in.
	static var allowInsecureHTTP: Bool {
		get { UserDefaults.standard.bool(forKey: allowInsecureHTTPKey) }
		set { UserDefaults.standard.set(newValue, forKey: allowInsecureHTTPKey) }
	}

	/// Validates a repository URL. Throws `Failure` when the URL is not an
	/// acceptable source transport.
	static func validate(_ url: URL) throws {
		guard let scheme = url.scheme?.lowercased() else {
			throw Failure.notHTTPS
		}
		guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
			throw Failure.invalidAuthority
		}
		switch scheme {
		case "https":
			return
		case "http":
			if allowInsecureHTTP { return }
			throw Failure.notHTTPS
		default:
			throw Failure.unsupportedScheme(scheme)
		}
	}

	/// Normalizes free-form user input to a URL: adds `https://` when no
	/// scheme is present (same behavior as the source add flow), then applies
	/// the transport policy.
	static func normalizeAndValidate(_ raw: String) throws -> URL {
		var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		let lower = cleaned.lowercased()
		if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
			cleaned = "https://" + cleaned
		}
		guard let url = URL(string: cleaned), url.host != nil, !url.absoluteString.isEmpty else {
			throw Failure.notHTTPS
		}
		try validate(url)
		return url
	}
}
