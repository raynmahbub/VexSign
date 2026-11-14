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
//  default and the setting states the risk. The opt-in is confined to local
//  hosts: enabling it must not turn a public catalog into a plaintext one,
//  and the app's ATS configuration no longer exempts public hosts either, so
//  a public `http://` repository is refused here with a sentence the user can
//  act on instead of failing later inside URLSession.
//

import Foundation
import NimbleExtensions

enum SourceURLPolicy {
	enum Failure: LocalizedError {
		case notHTTPS
		case invalidAuthority
		/// Plain HTTP was requested for a host that is not on the local network.
		case insecureRemoteHost(String)
		case unsupportedScheme(String)

		var errorDescription: String? {
			switch self {
			case .notHTTPS:
				String.localized("Repositories must use HTTPS. Enable 'Allow Insecure HTTP Sources' in Settings → Security if you really need a local HTTP repository.")
			case .invalidAuthority:
				String.localized("Repository URLs must have a host and must not embed a username or password.")
			case .insecureRemoteHost(let host):
				String.localized(
					"Plain HTTP is only available for a repository on your local network. Use HTTPS for '%@'.",
					arguments: host
				)
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
		try validateRestorable(url)
		// The one part of the policy that is about trust rather than shape: plain HTTP is
		// only acceptable after the user opts in, and only towards a local host. The
		// setting is presented as a LAN convenience; a public host cannot be made safe by
		// it, only quieter.
		guard url.scheme?.lowercased() == "http" else { return }
		guard allowInsecureHTTP else { throw Failure.notHTTPS }
		guard isLocalNetworkHost(url) else {
			throw Failure.insecureRemoteHost(url.host ?? url.absoluteString)
		}
	}

	/// Whether a URL names a host on the local network: loopback, a private or
	/// link-local address, `localhost`, or a `.local` name.
	static func isLocalNetworkHost(_ url: URL) -> Bool {
		guard let host = url.host else { return false }
		return LocalNetworkHost.matches(host)
	}

	/// The part of the policy that holds whatever transport the user accepts.
	///
	/// Used when reading a repository URL out of a backup archive. A restore is not a new
	/// trust decision — the user is reinstating a repository they already saved, which is why
	/// it does not need HTTPS on a LAN — but it is also not a reason to install a `file:` or
	/// `javascript:` URL as a source, or one with credentials embedded in it. Backups are
	/// files: they are handed around, copied, and downloaded, so what they name is untrusted.
	static func validateRestorable(_ url: URL) throws {
		guard let scheme = url.scheme?.lowercased() else {
			throw Failure.notHTTPS
		}
		guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
			throw Failure.invalidAuthority
		}
		switch scheme {
		case "https", "http":
			return
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
