//
//  URL+logSafeDescription.swift
//  VexSign
//

import Foundation

extension URL {
	/// A URL description that is safe to write to a log.
	///
	/// A full URL reaches a log with more than a host in it: premium feed tokens and
	/// signed download parameters live in the query, credentials can be embedded as
	/// user info, and the path can name a private repository. None of that helps
	/// anyone diagnosing a failure — the scheme, host and port do.
	///
	/// The value is safe to mark `privacy: .public`; leaving it at OSLog's default
	/// (`.private`) would render the diagnostic as `<private>` in Console.
	public var logSafeDescription: String {
		guard let scheme = scheme?.lowercased(), let host = host, !host.isEmpty else {
			return "<no host>"
		}
		let portSuffix = port.map { ":\($0)" } ?? ""
		return "\(scheme)://\(host.lowercased())\(portSuffix)"
	}
}
