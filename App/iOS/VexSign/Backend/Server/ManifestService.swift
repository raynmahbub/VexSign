//
//  ManifestService.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation
import OSLog

// itms-services:// only accepts a manifest from a publicly trusted host
enum ManifestService {
	private static let endpoints = [
		"https://vexsign-install.vexsign.workers.dev/genPlist",
		"https://api.palera.in/genPlist",
	]
	
	static func resolve(for app: AppInfoPresentable, payload: URL) async -> URL? {
		let candidates = endpoints.compactMap { _url(endpoint: $0, app: app, payload: payload) }
		return await select(candidates: candidates, serves: _serves)
	}

	/// Network-free selection rule used by `resolve`. Only a manifest endpoint that
	/// positively answered with an XML plist may become an `itms-services` URL.
	/// Returning an unverified candidate after every probe failed used to hand iOS
	/// a dead manifest link, which is indistinguishable from a real install request.
	static func select(
		candidates: [URL],
		serves: (URL) async -> Bool
	) async -> URL? {
		for candidate in candidates {
			if Task.isCancelled { return nil }
			if await serves(candidate) {
				return candidate
			}
			Logger.misc.error("Manifest endpoint unusable: \(candidate.host ?? "?", privacy: .public)")
		}
		return nil
	}
	
	private static func _url(endpoint: String, app: AppInfoPresentable, payload: URL) -> URL? {
		guard
			var comps = URLComponents(string: endpoint),
			let identifier = app.identifier,
			let name = app.name,
			let version = app.version
		else {
			return nil
		}
		
		comps.queryItems = [
			URLQueryItem(name: "bundleid", value: identifier),
			URLQueryItem(name: "name", value: name),
			URLQueryItem(name: "version", value: version),
			URLQueryItem(name: "fetchurl", value: payload.absoluteString),
		]
		
		return comps.url
	}
	
	private static func _serves(_ url: URL) async -> Bool {
		guard
			let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
			(response as? HTTPURLResponse)?.statusCode == 200
		else {
			return false
		}
		
		return data.starts(with: Array("<?xml".utf8))
	}
}
