//
//  LocalNetworkHost.swift
//  VexSign
//
//  Kept in its own file because the tvOS and visionOS companion targets compile
//  `CompanionClient` without the rest of the source-policy code.
//

import Foundation

// MARK: - Local network classification

/// One definition of "local network" for every place that grants an unencrypted
/// transport: repositories, package downloads and the companion client. Public
/// addresses and public names stay disallowed even when the user enables the HTTP
/// opt-in, because the opt-in is offered for a LAN, not as a general escape hatch.
enum LocalNetworkHost {
	/// `rawHost` is a `URL.host`: an IPv6 literal arrives without brackets.
	static func matches(_ rawHost: String) -> Bool {
		let bracketless = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
		let host = bracketless.hasSuffix(".") ? String(bracketless.dropLast()) : bracketless
		if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }

		if host.contains(":") {
			return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8")
				|| host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
		}

		let parts = host.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 4,
			  let first = Int(parts[0]),
			  let second = Int(parts[1]),
			  parts.allSatisfy({ part in
				  !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
					  && Int(part).map { (0...255).contains($0) } == true
			  }) else {
			return false
		}
		switch (first, second) {
		case (127, _), (10, _), (192, 168), (172, 16...31), (169, 254): return true
		default: return false
		}
	}
}
